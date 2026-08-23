# 03. NAS만으로 PostgreSQL 금융 데이터 런타임 구축하기

이 글은 개인 금융 데이터를 GitHub에 올리지 않고, self-hosted NAS에서 PostgreSQL을 운영하면서 GitHub Actions와 AI가 재현 가능한 방식으로 배포·검증하는 과정을 정리한다.

실제 가족 정보, 연봉, 계좌, 자산, 호스트명, 사용자명, SSH fingerprint는 포함하지 않는다.

## 목표

필요한 구성은 단순하다.

```text
GitHub public repository
  └─ 재사용 가능한 schema / migration / backup / tests

GitHub private repository
  └─ 개인 환경용 deployment policy / pinned SSH host public key

NAS
  └─ PostgreSQL data / runtime secret / raw import / backup
```

개인 금융 데이터의 Source of Truth는 NAS의 PostgreSQL이고 GitHub는 코드와 정책만 관리한다.

## 왜 Windows workstation을 배포 신뢰 경로에서 제거했나

처음에는 workstation에서 `ssh-keyscan`을 실행하고 결과를 GitHub Actions secret으로 전달하는 구조를 고려했다. 하지만 이는 다음 문제를 만든다.

- 최초 설정에 특정 PC가 필요하다.
- known_hosts 값이 secret UI를 거치며 잘못된 형식으로 저장될 수 있다.
- SSH host public key는 원래 비밀정보가 아닌데 secret으로 다루면서 운영이 복잡해진다.

대신 NAS가 자기 ED25519 SSH **public host key**를 직접 내보내도록 했다.

```sh
PUB=/etc/ssh/ssh_host_ed25519_key.pub
KEY="$(cat "$PUB")"
TYPE="$(printf '%s\n' "$KEY" | awk '{print $1}')"
DATA="$(printf '%s\n' "$KEY" | awk '{print $2}')"
printf '[nas.example]:2222 %s %s\n' "$TYPE" "$DATA"
```

이 public key를 private repository의 `known_hosts`에 pin한다. 이후 GitHub Actions는 계속 다음 정책을 사용한다.

```text
BatchMode=yes
IdentitiesOnly=yes
StrictHostKeyChecking=yes
```

즉 TOFU(`accept-new`)로 편의를 얻는 대신, NAS가 직접 제공한 host public key를 코드 리뷰 가능한 형태로 고정한다.

배포용 **SSH private key는 여전히 GitHub Actions secret**으로 유지한다. host public key와 deployment private key는 역할이 전혀 다르다.

## Synology bind mount에서 PostgreSQL PGDATA 권한 문제

PostgreSQL 공식 Docker 이미지는 `PGDATA`를 직접 초기화하고 해당 디렉터리에 쓸 수 있어야 한다. Docker의 bind mount는 host의 실제 파일시스템 권한과 ACL을 그대로 받으므로 NAS에서 미리 생성한 디렉터리가 지나치게 제한적이면 다음과 같이 실패할 수 있다.

```text
mkdir: can't create directory '/var/lib/postgresql/data/pgdata': Permission denied
```

이 프로젝트에서는 첫 초기화 동안만 bind mount의 **부모 디렉터리**를 다음처럼 만든다.

```sh
chmod 0733 "$POSTGRES_DATA"
```

`0733`은 container의 PostgreSQL 사용자가 `pgdata` child를 만들 수 있게 하지만 다른 사용자가 부모 내용을 list할 수는 없게 한다. PostgreSQL이 정상 기동한 직후에는 다시 다음처럼 잠근다.

```sh
chmod 0711 "$POSTGRES_DATA"
```

그리고 기존 `pgdata`가 있는데 그 DB와 짝을 이루는 runtime secret이 사라진 경우에는 새 비밀번호를 생성해 덮어쓰지 않고 **fail closed**한다.

이 부분은 NAS마다 ACL/UID 동작이 다를 수 있으므로 실제 환경에서 확인해야 한다. 핵심 원칙은 임의의 `chmod 777`이 아니라 **초기화에 필요한 최소 권한을 일시적으로 주고 즉시 회수하는 것**이다.

참고:
- Docker Official Image PostgreSQL: https://github.com/docker-library/docs/blob/master/postgres/README.md
- Docker bind mounts: https://docs.docker.com/engine/storage/bind-mounts/

## 검증 SQL은 container를 직접 대상으로 한다

처음에는 lifecycle과 SQL 확인을 모두 `docker compose exec`로 수행했다. CI에서는 문제없었지만 제한된 sudo Docker 환경의 실제 NAS에서는 lifecycle이 정상인데 검증 명령이 일관되지 않게 종료되는 경우가 있었다.

역할을 분리했다.

```text
Container lifecycle
  docker compose up / restart / force-recreate

Runtime verification
  docker exec <known-container> psql ...
```

예:

```sh
docker exec family-finance-postgres \
  psql -qAt -U finance_admin -d family_finance \
  -c 'SELECT COUNT(*) FROM meta.schema_migrations;'
```

실제 금융 분석에서 AI가 SQL을 직접 실행하도록 허용하더라도 같은 원칙을 쓸 수 있다. 연결 대상과 DB role을 먼저 고정하고 SQL 자유도를 그 안에서 제공한다.

## backup은 파일 생성만으로 성공 처리하지 않는다

백업의 완료 조건은 `pg_dump` 파일이 존재하는 것이 아니다.

이 프로젝트의 검증 순서는 다음과 같다.

```text
1. pg_isready
2. pg_dump --format=custom
3. 임시 verify database 생성
4. pg_restore --exit-on-error
5. 핵심 테이블 row count 비교
6. verify database 삭제
7. backup SHA-256 계산
```

즉 복구되지 않는 백업은 성공한 백업으로 취급하지 않는다.

이 과정도 `docker exec`를 사용해 Compose project resolution과 실제 container runtime verification을 분리했다.

## 최종 E2E 완료 조건

NAS 배포가 성공했다고 판단하려면 최소 다음을 모두 확인한다.

```text
SSH host pin validation
SSH identity
PostgreSQL health
migration application / idempotency
AI reader write denial
restart persistence
forced container recreation persistence
pg_dump -> isolated pg_restore
```

한 항목이라도 실패하면 GitHub Actions 전체를 실패시키고 이전 성공으로 간주하지 않는다.

## 실제 금융 데이터는 아직 넣지 않는다

인프라 검증과 실제 개인 데이터 적재를 분리하는 것이 중요하다.

먼저 synthetic data와 빈 production schema로 다음을 검증한다.

```text
deployment
permissions
persistence
backup / restore
```

그 다음에야 실제 자산·부채·소득·거래내역을 넣는다. 이렇게 하면 인프라를 고치는 과정에서 실제 금융 데이터를 불필요하게 노출하거나 손상시킬 가능성을 줄일 수 있다.

## 재현할 때 필요한 것

특정 Synology 모델이 필수는 아니다. 다음 정도면 동일한 패턴을 재현할 수 있다.

- Docker가 실행되는 NAS 또는 Linux server
- PostgreSQL official image
- GitHub public/private repositories
- GitHub Actions에서 NAS에 접근할 전용 SSH key
- NAS가 직접 출력한 SSH host public key
- 실제 금융 데이터를 Git 밖에 저장할 persistent storage

결국 중요한 구조는 다음 한 줄로 요약할 수 있다.

> GitHub에는 구현과 정책을 저장하고, NAS에는 금융 사실과 비밀정보를 저장하며, AI는 검증된 DB를 조회한다.
