from __future__ import annotations

import logging
import os
import time
from datetime import date, datetime
from decimal import Decimal
from typing import Any

import psycopg
from mcp.server import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations
from psycopg.rows import dict_row
from pydantic import BaseModel
from starlette.requests import Request
from starlette.responses import JSONResponse

LOGGER = logging.getLogger("family_finance_mcp")
logging.basicConfig(level=os.getenv("MCP_LOG_LEVEL", "INFO").upper())

SERVER_NAME = "Family Finance Control Plane"
MAX_ROWS = int(os.getenv("MCP_MAX_ROWS", "100"))
if MAX_ROWS < 1 or MAX_ROWS > 500:
    raise RuntimeError("MCP_MAX_ROWS must be between 1 and 500")

READ_ONLY = ToolAnnotations(
    read_only_hint=True,
    destructive_hint=False,
    idempotent_hint=True,
    open_world_hint=False,
)


class RowsResult(BaseModel):
    rows: list[dict[str, str | int | bool | None]]
    row_count: int
    truncated: bool = False


class HealthResult(BaseModel):
    status: str
    service: str


def _env_required(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise RuntimeError(f"required environment variable is missing: {name}")
    return value


def _safe_value(value: Any) -> str | int | bool | None:
    if value is None or isinstance(value, (str, int, bool)):
        return value
    if isinstance(value, (Decimal, date, datetime)):
        return str(value)
    return str(value)


def _serialize(rows: list[dict[str, Any]]) -> RowsResult:
    truncated = len(rows) > MAX_ROWS
    visible = rows[:MAX_ROWS]
    return RowsResult(
        rows=[{key: _safe_value(value) for key, value in row.items()} for row in visible],
        row_count=len(visible),
        truncated=truncated,
    )


def _validate_months(months: int, maximum: int = 60) -> int:
    if months < 1 or months > maximum:
        raise ValueError(f"months must be between 1 and {maximum}")
    return months


def _validate_limit(limit: int, maximum: int = 100) -> int:
    if limit < 1 or limit > maximum:
        raise ValueError(f"limit must be between 1 and {maximum}")
    return limit


def _connection_kwargs() -> dict[str, Any]:
    return {
        "host": os.getenv("FINANCE_DB_HOST", "db"),
        "port": int(os.getenv("FINANCE_DB_PORT", "5432")),
        "dbname": os.getenv("FINANCE_DB_NAME", "family_finance"),
        "user": _env_required("FINANCE_MCP_DB_USER"),
        "password": _env_required("FINANCE_MCP_DB_PASSWORD"),
        "application_name": "family_finance_mcp",
        "connect_timeout": 5,
        "options": (
            "-c default_transaction_read_only=on "
            "-c statement_timeout=10000 "
            "-c lock_timeout=2000 "
            "-c idle_in_transaction_session_timeout=5000"
        ),
        "row_factory": dict_row,
        "autocommit": True,
    }


async def _query(tool: str, sql: str, params: tuple[Any, ...] = ()) -> RowsResult:
    started = time.monotonic()
    try:
        async with await psycopg.AsyncConnection.connect(**_connection_kwargs()) as conn:
            async with conn.cursor() as cur:
                await cur.execute(sql, params)
                rows = await cur.fetchall()
        result = _serialize(rows)
        LOGGER.info(
            "mcp_tool_complete tool=%s rows=%d truncated=%s duration_ms=%d",
            tool,
            result.row_count,
            result.truncated,
            int((time.monotonic() - started) * 1000),
        )
        return result
    except Exception as exc:
        LOGGER.error(
            "mcp_tool_failed tool=%s error_type=%s duration_ms=%d",
            tool,
            type(exc).__name__,
            int((time.monotonic() - started) * 1000),
        )
        raise RuntimeError("financial data query failed") from None


mcp = MCPServer(
    SERVER_NAME,
    version="1.0.0",
    instructions=(
        "Read-only household-finance tools backed by deterministic PostgreSQL views. "
        "Do not infer missing values as zero. No arbitrary SQL or mutation tools are exposed."
    ),
)


@mcp.custom_route("/health", methods=["GET"], include_in_schema=False)
async def health(_: Request) -> JSONResponse:
    return JSONResponse(HealthResult(status="ok", service="family-finance-mcp").model_dump())


@mcp.tool(title="List finance households", annotations=READ_ONLY)
async def list_households() -> RowsResult:
    """List household labels and base currencies available through the curated MCP boundary."""
    return await _query(
        "list_households",
        "SELECT household_label, base_currency FROM analytics.v_household_directory ORDER BY household_label LIMIT %s",
        (MAX_ROWS + 1,),
    )


@mcp.tool(title="Get financial snapshot", annotations=READ_ONLY)
async def financial_snapshot(household_label: str, currency: str | None = None) -> RowsResult:
    """Return deterministic current income, fixed-cost, net-worth and liquid-reserve metrics."""
    return await _query(
        "financial_snapshot",
        """
        SELECT s.currency, s.annual_gross_income, s.monthly_net_income,
               s.monthly_fixed_obligations, s.fixed_cost_headroom,
               s.net_worth, s.liquid_reserve, s.income_as_of_date
        FROM analytics.v_household_financial_snapshot_by_currency s
        JOIN analytics.v_household_directory d USING (household_id)
        WHERE d.household_label = %s
          AND (%s::text IS NULL OR s.currency::text = %s::text)
        ORDER BY s.currency
        LIMIT %s
        """,
        (household_label, currency, currency, MAX_ROWS + 1),
    )


@mcp.tool(title="Get monthly cash flow", annotations=READ_ONLY)
async def cash_flow(household_label: str, months: int = 12, currency: str | None = None) -> RowsResult:
    """Return the latest N monthly inflow, outflow and net-cash-flow rows from recorded transactions."""
    months = _validate_months(months, 36)
    return await _query(
        "cash_flow",
        """
        SELECT month, currency, inflow, outflow, net_cash_flow, transaction_count
        FROM (
          SELECT c.month, c.currency, c.inflow, c.outflow, c.net_cash_flow, c.transaction_count
          FROM analytics.v_monthly_cash_flow_calendar c
          JOIN analytics.v_household_directory d USING (household_id)
          WHERE d.household_label = %s
            AND (%s::text IS NULL OR c.currency::text = %s::text)
          ORDER BY c.month DESC, c.currency
          LIMIT %s
        ) recent
        ORDER BY month, currency
        """,
        (household_label, currency, currency, min(MAX_ROWS + 1, months * 8)),
    )


@mcp.tool(title="Summarize spending categories", annotations=READ_ONLY)
async def spending_summary(
    household_label: str,
    months: int = 3,
    currency: str | None = None,
    limit: int = 20,
) -> RowsResult:
    """Aggregate recent recorded spending by category without exposing counterparties or descriptions."""
    months = _validate_months(months, 24)
    limit = _validate_limit(limit, 50)
    return await _query(
        "spending_summary",
        """
        WITH scoped AS (
          SELECT s.*
          FROM analytics.v_monthly_spending_by_category s
          JOIN analytics.v_household_directory d USING (household_id)
          WHERE d.household_label = %s
            AND (%s::text IS NULL OR s.currency::text = %s::text)
        ), latest AS (
          SELECT currency, MAX(month) AS latest_month FROM scoped GROUP BY currency
        )
        SELECT s.currency, s.category,
               SUM(s.spending)::numeric(20,2) AS spending,
               SUM(s.transaction_count)::bigint AS transaction_count
        FROM scoped s
        JOIN latest l USING (currency)
        WHERE s.month >= (l.latest_month - ((%s::int - 1) * interval '1 month'))::date
        GROUP BY s.currency, s.category
        ORDER BY spending DESC, s.category
        LIMIT %s
        """,
        (household_label, currency, currency, months, min(MAX_ROWS + 1, limit + 1)),
    )


@mcp.tool(title="Get net worth history", annotations=READ_ONLY)
async def net_worth_history(household_label: str, months: int = 12, currency: str | None = None) -> RowsResult:
    """Return monthly deterministic net-worth history and month-over-month change."""
    months = _validate_months(months, 60)
    return await _query(
        "net_worth_history",
        """
        SELECT month, currency, account_balances, other_assets, liabilities,
               net_worth, previous_month_net_worth, net_worth_change
        FROM (
          SELECT n.*
          FROM analytics.v_net_worth_history_by_currency n
          JOIN analytics.v_household_directory d USING (household_id)
          WHERE d.household_label = %s
            AND (%s::text IS NULL OR n.currency::text = %s::text)
          ORDER BY n.month DESC, n.currency
          LIMIT %s
        ) recent
        ORDER BY month, currency
        """,
        (household_label, currency, currency, min(MAX_ROWS + 1, months * 8)),
    )


@mcp.tool(title="Get emergency reserve coverage", annotations=READ_ONLY)
async def emergency_reserve(household_label: str, currency: str | None = None) -> RowsResult:
    """Return liquid reserve and fixed-obligation coverage months; missing obligation basis remains explicit."""
    return await _query(
        "emergency_reserve",
        """
        SELECT e.currency, e.liquid_reserve, e.monthly_fixed_obligations,
               e.coverage_months, e.coverage_status
        FROM analytics.v_emergency_reserve_coverage e
        JOIN analytics.v_household_directory d USING (household_id)
        WHERE d.household_label = %s
          AND (%s::text IS NULL OR e.currency::text = %s::text)
        ORDER BY e.currency
        LIMIT %s
        """,
        (household_label, currency, currency, MAX_ROWS + 1),
    )


@mcp.tool(title="Get scenario outcomes", annotations=READ_ONLY)
async def scenario_outcomes(household_label: str, currency: str | None = None, limit: int = 25) -> RowsResult:
    """Return deterministic active career/housing/childcare scenario outcomes without raw ledger access."""
    limit = _validate_limit(limit, 50)
    return await _query(
        "scenario_outcomes",
        """
        SELECT s.scenario_label, s.currency, s.childcare_risk_score,
               s.housing_candidate_label, s.selected_career_count,
               s.annual_gross_income, s.annual_net_income,
               s.monthly_commute_cost, s.commute_minutes_per_week,
               s.monthly_housing_cost, s.monthly_childcare_cost,
               s.monthly_household_services_cost, s.monthly_other_operating_cost,
               s.monthly_modeled_operating_cost, s.annual_modeled_operating_cost,
               s.annual_net_after_modeled_costs, s.required_housing_cash,
               s.current_liquid_reserve, s.projected_liquid_reserve_after_housing,
               s.missing_gross_income_count, s.missing_net_income_count,
               s.missing_commute_cost_count, s.missing_commute_time_count
        FROM analytics.v_household_scenario_outcomes s
        JOIN analytics.v_household_directory d USING (household_id)
        WHERE d.household_label = %s AND s.active
          AND (%s::text IS NULL OR s.currency::text = %s::text)
        ORDER BY s.scenario_label
        LIMIT %s
        """,
        (household_label, currency, currency, min(MAX_ROWS + 1, limit + 1)),
    )


def main() -> None:
    host = os.getenv("MCP_HOST", "0.0.0.0")
    port = int(os.getenv("MCP_PORT", "8000"))
    allowed_hosts = [
        item.strip()
        for item in os.getenv(
            "MCP_ALLOWED_HOSTS",
            "family-finance-mcp:8000,mcp:8000,localhost:8000,127.0.0.1:8000",
        ).split(",")
        if item.strip()
    ]
    if not allowed_hosts:
        raise RuntimeError("MCP_ALLOWED_HOSTS must contain at least one Host value")
    security = TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=allowed_hosts,
        allowed_origins=[],
    )
    mcp.run(
        transport="streamable-http",
        host=host,
        port=port,
        stateless_http=True,
        json_response=True,
        max_request_body_size=65536,
        transport_security=security,
    )


if __name__ == "__main__":
    main()
