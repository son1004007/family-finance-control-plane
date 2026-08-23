FROM python:3.12.14-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app
COPY collector/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY collector/family_finance_collector /app/family_finance_collector

RUN useradd --create-home --uid 10002 --shell /usr/sbin/nologin collector \
    && chown -R collector:collector /app
USER collector

CMD ["python", "-m", "family_finance_collector.main"]
