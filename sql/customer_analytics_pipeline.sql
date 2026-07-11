/* ============================================================
   CUSTOMER ANALYTICS PIPELINE
   RFM Segmentation | Customer Lifetime Value | Churn Analysis
   
   Dataset : UCI Online Retail Dataset (~541,909 rows)
   Source  : https://archive.ics.uci.edu/dataset/352/online+retail
   Tool    : DuckDB v1.5.4
   Author  : Ahmad Farid
   ============================================================ */


/* ------------------------------------------------------------
   STEP 0 — SETUP
   ------------------------------------------------------------ */
INSTALL excel;
LOAD excel;


/* ------------------------------------------------------------
   STEP 1 — LOAD RAW DATA
   Semua kolom dipaksa jadi VARCHAR dulu (all_varchar = true)
   karena kolom InvoiceNo berisi campuran angka & kode "C..."
   (cancelled orders), yang bikin auto type-detection gagal.
   ------------------------------------------------------------ */
CREATE TABLE raw_transactions AS
SELECT * FROM read_xlsx(
    'C:/Users/ahmad farid/Downloads/custumer analyst/Online Retail.xlsx',
    all_varchar = true
);

-- Cek struktur & jumlah baris
DESCRIBE raw_transactions;
SELECT COUNT(*) FROM raw_transactions;                 -- 541,909 rows


/* ------------------------------------------------------------
   STEP 2 — DATA QUALITY CHECK
   ------------------------------------------------------------ */

-- Missing CustomerID
SELECT COUNT(*) AS missing_customerid
FROM raw_transactions
WHERE CustomerID IS NULL OR CustomerID = '';           -- 135,080 rows (~24.9%)

-- Cancelled orders (InvoiceNo diawali huruf 'C')
SELECT COUNT(*) AS cancelled_orders
FROM raw_transactions
WHERE InvoiceNo LIKE 'C%';                              -- 9,288 rows (~1.7%)

-- Quantity / UnitPrice tidak valid (<= 0)
SELECT COUNT(*) AS negative_or_zero
FROM raw_transactions
WHERE TRY_CAST(Quantity AS INTEGER) <= 0
   OR TRY_CAST(UnitPrice AS DOUBLE) <= 0;                -- 11,805 rows (~2.2%)


/* ------------------------------------------------------------
   STEP 3 — DATA CLEANING
   - Convert tipe data yang benar (Quantity, UnitPrice, CustomerID)
   - Convert InvoiceDate dari Excel serial date -> timestamp asli
   - Buang: missing CustomerID, cancelled orders, qty/price <= 0
   - Tambah kolom TotalPrice (Quantity x UnitPrice)
   ------------------------------------------------------------ */
CREATE TABLE clean_transactions AS
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

-- Validasi hasil cleaning
DESCRIBE clean_transactions;
SELECT COUNT(*) FROM clean_transactions;                -- 397,884 rows
SELECT MIN(InvoiceDate), MAX(InvoiceDate) FROM clean_transactions;
-- Expected: 2010-12-01 s/d 2011-12-09


/* ------------------------------------------------------------
   STEP 4 — RFM BASE (Recency, Frequency, Monetary)
   Reference date = tanggal transaksi terakhir di dataset
   (bukan tanggal hari ini, karena ini data historis)
   ------------------------------------------------------------ */
CREATE TABLE rfm_base AS
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

SELECT COUNT(*) FROM rfm_base;                          -- 4,338 unique customers


/* ------------------------------------------------------------
   STEP 5 — RFM SCORING (1-5, pakai NTILE)
   Recency  : makin kecil makin baik -> urutan DESC biar score 5 = paling baru
   Frequency: makin besar makin baik -> urutan ASC
   Monetary : makin besar makin baik -> urutan ASC
   ------------------------------------------------------------ */
CREATE TABLE rfm_scored AS
SELECT
    CustomerID,
    Recency,
    Frequency,
    Monetary,
    NTILE(5) OVER (ORDER BY Recency DESC) AS R_Score,
    NTILE(5) OVER (ORDER BY Frequency ASC) AS F_Score,
    NTILE(5) OVER (ORDER BY Monetary ASC) AS M_Score
FROM rfm_base;


/* ------------------------------------------------------------
   STEP 6 — RFM SEGMENTATION
   Mapping skor RFM ke label segmen bisnis
   ------------------------------------------------------------ */
CREATE TABLE rfm_segmented AS
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

-- Distribusi customer & revenue per segmen
SELECT Segment, COUNT(*) AS jumlah_customer,
       ROUND(AVG(Monetary), 2) AS avg_monetary,
       ROUND(SUM(Monetary), 2) AS total_revenue
FROM rfm_segmented
GROUP BY Segment
ORDER BY total_revenue DESC;


/* ------------------------------------------------------------
   STEP 7 — CUSTOMER TENURE
   Dipakai sebagai basis estimasi lifespan untuk CLV
   ------------------------------------------------------------ */
CREATE TABLE customer_tenure AS
SELECT
    CustomerID,
    MIN(InvoiceDate) AS FirstPurchase,
    MAX(InvoiceDate) AS LastPurchase,
    DATE_DIFF('day', MIN(InvoiceDate), MAX(InvoiceDate)) AS Tenure_Days
FROM clean_transactions
GROUP BY CustomerID;

SELECT AVG(Tenure_Days) AS avg_tenure_days FROM customer_tenure WHERE Tenure_Days > 0;
-- avg ~203 hari (~6.7 bulan)


/* ------------------------------------------------------------
   STEP 8 — CUSTOMER LIFETIME VALUE (CLV)
   Formula: CLV = AOV x Monthly Purchase Rate x Estimated Lifespan (bulan)
   
   Catatan penting: Tenure_Days di-floor minimal 30 hari
   (pakai GREATEST) untuk menghindari division by near-zero
   yang bisa membuat Monthly_Purchase_Rate meledak jadi angka
   ekstrem pada customer dengan tenure yang sangat pendek.
   ------------------------------------------------------------ */
CREATE TABLE clv_analysis AS
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

-- CLV rata-rata & total per segmen
SELECT
    Segment,
    COUNT(*) AS jumlah_customer,
    ROUND(AVG(Historical_CLV), 2) AS avg_historical_clv,
    ROUND(AVG(Predicted_CLV), 2) AS avg_predicted_clv,
    ROUND(SUM(Predicted_CLV), 2) AS total_predicted_clv
FROM clv_analysis
GROUP BY Segment
ORDER BY total_predicted_clv DESC;

-- Top 10 customer by Predicted CLV
SELECT CustomerID, Segment, Historical_CLV, Predicted_CLV
FROM clv_analysis
ORDER BY Predicted_CLV DESC
LIMIT 10;


/* ------------------------------------------------------------
   STEP 9 — CHURN ANALYSIS
   Definisi churn: customer tidak bertransaksi lagi
   dalam 90 hari terakhir (dihitung dari Recency)
   ------------------------------------------------------------ */
CREATE TABLE churn_analysis AS
SELECT
    c.CustomerID,
    c.Recency,
    c.Frequency,
    c.Monetary,
    rs.Segment,
    CASE
        WHEN c.Recency > 90 THEN 'Churned'
        ELSE 'Active'
    END AS Churn_Status
FROM rfm_base c
JOIN rfm_segmented rs ON c.CustomerID = rs.CustomerID;

-- Overall churn rate
SELECT
    Churn_Status,
    COUNT(*) AS jumlah_customer,
    ROUND(COUNT(*) * 100.0 / (SELECT COUNT(*) FROM churn_analysis), 2) AS percentage,
    ROUND(SUM(Monetary), 2) AS total_revenue_lost_or_active
FROM churn_analysis
GROUP BY Churn_Status;
-- Churned: 1,449 customers (33.4%) | Active: 2,889 customers (66.6%)

-- Churn rate per segmen
SELECT
    Segment,
    COUNT(*) AS total_customer,
    SUM(CASE WHEN Churn_Status = 'Churned' THEN 1 ELSE 0 END) AS churned_customer,
    ROUND(SUM(CASE WHEN Churn_Status = 'Churned' THEN 1 ELSE 0 END) * 100.0 / COUNT(*), 2) AS churn_rate_pct
FROM churn_analysis
GROUP BY Segment
ORDER BY churn_rate_pct DESC;


/* ------------------------------------------------------------
   STEP 10 — MASTER TABLE
   Gabungan RFM + CLV + Churn, 1 baris per customer
   ------------------------------------------------------------ */
CREATE TABLE master_customer_analytics AS
SELECT
    rs.CustomerID,
    rs.Recency,
    rs.Frequency,
    rs.Monetary,
    rs.R_Score,
    rs.F_Score,
    rs.M_Score,
    rs.RFM_Segment_Code,
    rs.Segment,
    clv.AOV,
    clv.Monthly_Purchase_Rate,
    clv.Predicted_CLV,
    clv.Tenure_Days,
    ch.Churn_Status
FROM rfm_segmented rs
JOIN clv_analysis clv ON rs.CustomerID = clv.CustomerID
JOIN churn_analysis ch ON rs.CustomerID = ch.CustomerID;

SELECT COUNT(*) FROM master_customer_analytics;         -- 4,338 rows


/* ------------------------------------------------------------
   STEP 11 — EXPORT TO CSV (untuk diimport ke Power BI)
   ------------------------------------------------------------ */
COPY master_customer_analytics 
TO 'C:/Users/ahmad farid/Downloads/custumer analyst/master_customer_analytics.csv' 
(HEADER, DELIMITER ',');

COPY clean_transactions 
TO 'C:/Users/ahmad farid/Downloads/custumer analyst/clean_transactions.csv' 
(HEADER, DELIMITER ',');


/* ============================================================
   OUTPUT FILES:
   1. master_customer_analytics.csv -> level customer (4,338 rows)
      Dipakai untuk: RFM Segmentation, CLV, Churn Analysis
   2. clean_transactions.csv -> level transaksi (397,884 rows)
      Dipakai untuk: Overview / Executive Summary (trend, top product, dll)
   ============================================================ */
