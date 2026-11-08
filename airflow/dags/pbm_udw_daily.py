"""
PBM UDW daily pipeline: one run per load date.
land the day's files -> dbt build (incremental) -> refresh the client report.
"""

from datetime import datetime, timedelta
from pathlib import Path

try:                                    # Airflow 3
    from airflow.sdk import DAG
    from airflow.providers.standard.operators.bash import BashOperator
    from airflow.providers.standard.operators.empty import EmptyOperator
except ImportError:                     # Airflow 2
    from airflow import DAG
    from airflow.operators.bash import BashOperator
    from airflow.operators.empty import EmptyOperator

REPO = Path(__file__).resolve().parents[2]          # .../pbm-udw
DBT = f"{REPO}/.venv/bin/dbt"                       # dbt lives in its own venv
DBT_DIR = f"{REPO}/pbm_dbt"

default_args ={
    "owner": "Piyoosh",
    "retries": 2,                                   # retry a failed task twice...
    "retry_delay": timedelta(minutes=5),            # ...5 minutes apart
}
with DAG(
    dag_id="pbm_udw_daily",
    description="Daily PBM load: land files, build incrementally, refresh the client report",
    schedule="0 6 * * *",   # 6 AM daily
    start_date=datetime(2026,10,1),
    end_date=datetime(2026,10,4),    # our synthetic data stops here
    catchup=True,                    # create a run for every day since start_date
    max_active_runs=1,               # one day at a time, in order (incremental!)
    default_args = default_args,
    tags=["pbm","dbt"],
) as dag:

    # Stands in for ingestion. In production this is a sensor waiting for the vendor's file.
    land_files = BashOperator(
        task_id="land_files",
        bash_command=(
            f"cd {REPO} && {REPO}/.venv/bin/python generator/generate_pbm_data.py "
            "--load-date {{ ds }} --seed 42 --late-reversals --claims 3000 --window-days 3"
        ),
    )

    dbt_build = BashOperator(
        task_id="dbt_build",
        bash_command = f"cd {DBT_DIR} && {DBT} build --exclude-resource-type unit_test",
    )

        # Placeholder: in production, call the Power BI REST API to refresh the dataset.
    refresh_client_report = EmptyOperator(task_id="refresh_client_report")

    land_files >> dbt_build >> refresh_client_report