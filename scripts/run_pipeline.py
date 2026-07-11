"""
==============================================================
CUSTOMER ANALYTICS PIPELINE — AUTOMATION SCRIPT
RFM Segmentation | Customer Lifetime Value | Churn Analysis

Script ini menjalankan seluruh pipeline SQL (lihat sql/customer_analytics_pipeline.sql)
secara otomatis end-to-end menggunakan Python + DuckDB, mulai dari load data mentah
sampai export CSV siap pakai untuk Power BI.

Requirement:
    pip install duckdb

Cara pakai:
    python run_pipeline.py --input "path/ke/Online Retail.xlsx" --output "path/output/folder"

Author: Ahmad Farid
==============================================================
"""

import argparse
import os
import sys
import duckdb


def run_pipeline(input_path: str, output_dir: str, db_path: str = "customer_analytics.duckdb"):
    """Menjalankan seluruh pipeline customer analytics dan export hasil ke CSV."""

    if not os.path.exists(input_path):
        print(f"[ERROR] File input tidak ditemukan: {input_path}")
        sys.exit(1)

    os.makedirs(output_dir, exist_ok=True)

    print(f"[INFO] Menghubungkan ke database: {db_path}")
    con = duckdb.connect(db_path)

    # ----------------------------------------------------------------
    # STEP 1 — SETUP & LOAD RAW DATA
    # ----------------------------------------------------------------
    print("[STEP 1] Setup extension & load raw data...")
    con.execute("INSTALL excel; LOAD excel;")

    # Escape single quotes pada path biar aman di query SQL
    safe_input_path = input_path.replace("'", "''")

    con.execute(f"""
        CREATE OR REPLACE TABLE raw_transactions AS
        SELECT * FROM read_xlsx('{safe_input_path}', all_varchar = true);
    """)

    total_raw = con.execute("SELECT COUNT(*) FROM raw_transactions").fetchone()[0]
    print(f"         -> {total_raw:,} baris berhasil dimuat")

    # ----------------------------------------------------------------
    # STEP 2 — DATA QUALITY CHECK (dicetak sebagai log, tidak fatal)
    # ----------------------------------------------------------------
    print("[STEP 2] Cek kualitas data...")
    missing_cid = con.execute("""
        SELECT COUNT(*) FROM raw_transactions
        WHERE CustomerID IS NULL OR CustomerID = ''
    """).fetchone()[0]
    cancelled = con.execute("""
        SELECT COUNT(*) FROM raw_transactions WHERE InvoiceNo LIKE 'C%'
    """).fetchone()[0]
    invalid_qty_price = con.execute("""
        SELECT COUNT(*) FROM raw_transactions
        WHERE TRY_CAST(Quantity AS INTEGER) <= 0
           OR TRY_CAST(UnitPrice AS DOUBLE) <= 0
    """).fetchone()[0]
    print(f"         -> Missing CustomerID : {missing_cid:,}")
    print(f"         -> Cancelled orders   : {cancelled:,}")
    print(f"         -> Invalid qty/price  : {invalid_qty_price:,}")

    # ----------------------------------------------------------------
    # STEP 3 — DATA CLEANING
    # ----------------------------------------------------------------
    print("[STEP 3] Cleaning data...")
    con.execute("""
        CREATE OR REPLACE TABLE clean_transactions AS
        SELECT
            InvoiceNo,
            StockCode,
            Description,
            TRY_CAST(Quantity AS INTEGER) AS Quantity,
            (TIMESTAMP '1899-12-30' + TRY_CAST(InvoiceDate AS DOUBLE) * INTERVAL '1 day') AS InvoiceDate,
            TRY_CAST(UnitPrice AS DOUBLE) AS UnitPrice,
            TRY_CAST(CustomerID AS INTEGER) AS CustomerID,
            Country,
            TRY_CAST(Quantity AS INTEGER) * TRY_CAST(UnitPrice AS DOUBLE) AS TotalPrice
        FROM raw_transactions
        WHERE
            CustomerID IS NOT NULL AND CustomerID != ''
            AND InvoiceNo NOT LIKE 'C%'
            AND TRY_CAST(Quantity AS INTEGER) > 0
            AND TRY_CAST(UnitPrice AS DOUBLE) > 0;
    """)
    total_clean = con.execute("SELECT COUNT(*) FROM clean_transactions").fetchone()[0]
    date_range = con.execute("SELECT MIN(InvoiceDate), MAX(InvoiceDate) FROM clean_transactions").fetchone()
    print(f"         -> {total_clean:,} baris tersisa setelah cleaning")
    print(f"         -> Rentang tanggal: {date_range[0]} s/d {date_range[1]}")

    # ----------------------------------------------------------------
    # STEP 4 — RFM BASE
    # ----------------------------------------------------------------
    print("[STEP 4] Menghitung RFM base...")
    con.execute("""
        CREATE OR REPLACE TABLE rfm_base AS
        WITH reference_date AS (
            SELECT MAX(InvoiceDate) AS max_date FROM clean_transactions
        )
        SELECT
            CustomerID,
            DATE_DIFF('day', MAX(InvoiceDate), (SELECT max_date FROM reference_date)) AS Recency,
            COUNT(DISTINCT InvoiceNo) AS Frequency,
            SUM(TotalPrice) AS Monetary
        FROM clean_transactions
        GROUP BY CustomerID;
    """)
    total_customers = con.execute("SELECT COUNT(*) FROM rfm_base").fetchone()[0]
    print(f"         -> {total_customers:,} pelanggan unik")

    # ----------------------------------------------------------------
    # STEP 5 — RFM SCORING
    # ----------------------------------------------------------------
    print("[STEP 5] Menghitung RFM scoring...")
    con.execute("""
        CREATE OR REPLACE TABLE rfm_scored AS
        SELECT
            CustomerID, Recency, Frequency, Monetary,
            NTILE(5) OVER (ORDER BY Recency DESC) AS R_Score,
            NTILE(5) OVER (ORDER BY Frequency ASC) AS F_Score,
            NTILE(5) OVER (ORDER BY Monetary ASC) AS M_Score
        FROM rfm_base;
    """)

    # ----------------------------------------------------------------
    # STEP 6 — RFM SEGMENTATION
    # ----------------------------------------------------------------
    print("[STEP 6] Melakukan segmentasi RFM...")
    con.execute("""
        CREATE OR REPLACE TABLE rfm_segmented AS
        SELECT
            *,
            CONCAT(R_Score, F_Score, M_Score) AS RFM_Segment_Code,
            CASE
                WHEN R_Score >= 4 AND F_Score >= 4 AND M_Score >= 4 THEN 'Champions'
                WHEN R_Score >= 3 AND F_Score >= 3 AND M_Score >= 3 THEN 'Loyal Customers'
                WHEN R_Score >= 4 AND F_Score <= 2 THEN 'New Customers'
                WHEN R_Score >= 3 AND F_Score <= 2 AND M_Score <= 2 THEN 'Potential Loyalist'
                WHEN R_Score <= 2 AND F_Score >= 4 AND M_Score >= 4 THEN 'At Risk'
                WHEN R_Score <= 2 AND F_Score >= 3 THEN 'Cant Lose Them'
                WHEN R_Score <= 2 AND F_Score <= 2 AND M_Score <= 2 THEN 'Hibernating'
                WHEN R_Score <= 1 AND F_Score <= 1 THEN 'Lost'
                ELSE 'Others'
            END AS Segment
        FROM rfm_scored;
    """)

    # ----------------------------------------------------------------
    # STEP 7 — CUSTOMER TENURE
    # ----------------------------------------------------------------
    print("[STEP 7] Menghitung customer tenure...")
    con.execute("""
        CREATE OR REPLACE TABLE customer_tenure AS
        SELECT
            CustomerID,
            MIN(InvoiceDate) AS FirstPurchase,
            MAX(InvoiceDate) AS LastPurchase,
            DATE_DIFF('day', MIN(InvoiceDate), MAX(InvoiceDate)) AS Tenure_Days
        FROM clean_transactions
        GROUP BY CustomerID;
    """)

    # ----------------------------------------------------------------
    # STEP 8 — CUSTOMER LIFETIME VALUE (CLV)
    # ----------------------------------------------------------------
    print("[STEP 8] Menghitung Customer Lifetime Value...")
    con.execute("""
        CREATE OR REPLACE TABLE clv_analysis AS
        SELECT
            r.CustomerID,
            r.Recency,
            r.Frequency,
            r.Monetary AS Historical_CLV,
            t.Tenure_Days,
            ROUND(r.Monetary / r.Frequency, 2) AS AOV,
            ROUND(r.Frequency / (GREATEST(t.Tenure_Days, 30) / 30.0), 4) AS Monthly_Purchase_Rate,
            12 AS Estimated_Lifespan_Months,
            ROUND(
                (r.Monetary / r.Frequency)
                * (r.Frequency / (GREATEST(t.Tenure_Days, 30) / 30.0))
                * 12
            , 2) AS Predicted_CLV,
            rs.Segment
        FROM rfm_base r
        JOIN customer_tenure t ON r.CustomerID = t.CustomerID
        JOIN rfm_segmented rs ON r.CustomerID = rs.CustomerID;
    """)

    # ----------------------------------------------------------------
    # STEP 9 — CHURN ANALYSIS
    # ----------------------------------------------------------------
    print("[STEP 9] Menandai status churn (threshold: 90 hari)...")
    con.execute("""
        CREATE OR REPLACE TABLE churn_analysis AS
        SELECT
            c.CustomerID, c.Recency, c.Frequency, c.Monetary, rs.Segment,
            CASE WHEN c.Recency > 90 THEN 'Churned' ELSE 'Active' END AS Churn_Status
        FROM rfm_base c
        JOIN rfm_segmented rs ON c.CustomerID = rs.CustomerID;
    """)
    churn_summary = con.execute("""
        SELECT Churn_Status, COUNT(*), ROUND(SUM(Monetary), 2)
        FROM churn_analysis GROUP BY Churn_Status
    """).fetchall()
    for status, count, revenue in churn_summary:
        print(f"         -> {status}: {count:,} pelanggan (revenue: {revenue:,.2f})")

    # ----------------------------------------------------------------
    # STEP 10 — MASTER TABLE
    # ----------------------------------------------------------------
    print("[STEP 10] Menggabungkan master table...")
    con.execute("""
        CREATE OR REPLACE TABLE master_customer_analytics AS
        SELECT
            rs.CustomerID, rs.Recency, rs.Frequency, rs.Monetary,
            rs.R_Score, rs.F_Score, rs.M_Score, rs.RFM_Segment_Code, rs.Segment,
            clv.AOV, clv.Monthly_Purchase_Rate, clv.Predicted_CLV, clv.Tenure_Days,
            ch.Churn_Status
        FROM rfm_segmented rs
        JOIN clv_analysis clv ON rs.CustomerID = clv.CustomerID
        JOIN churn_analysis ch ON rs.CustomerID = ch.CustomerID;
    """)

    # ----------------------------------------------------------------
    # STEP 11 — EXPORT TO CSV
    # ----------------------------------------------------------------
    print("[STEP 11] Export hasil ke CSV...")
    master_path = os.path.join(output_dir, "master_customer_analytics.csv")
    transactions_path = os.path.join(output_dir, "clean_transactions.csv")

    safe_master_path = master_path.replace("'", "''")
    safe_transactions_path = transactions_path.replace("'", "''")

    con.execute(f"COPY master_customer_analytics TO '{safe_master_path}' (HEADER, DELIMITER ',');")
    con.execute(f"COPY clean_transactions TO '{safe_transactions_path}' (HEADER, DELIMITER ',');")

    print(f"         -> {master_path}")
    print(f"         -> {transactions_path}")

    con.close()
    print("\n[DONE] Pipeline selesai dijalankan. Database tersimpan di:", db_path)


def main():
    parser = argparse.ArgumentParser(
        description="Menjalankan pipeline customer analytics (RFM, CLV, Churn) end-to-end."
    )
    parser.add_argument(
        "--input", required=True,
        help="Path ke file Excel Online Retail Dataset (contoh: 'data/Online Retail.xlsx')"
    )
    parser.add_argument(
        "--output", default="output",
        help="Folder tujuan untuk menyimpan hasil CSV (default: ./output)"
    )
    parser.add_argument(
        "--db", default="customer_analytics.duckdb",
        help="Nama file database DuckDB yang akan dibuat (default: customer_analytics.duckdb)"
    )
    args = parser.parse_args()

    run_pipeline(input_path=args.input, output_dir=args.output, db_path=args.db)


if __name__ == "__main__":
    main()
