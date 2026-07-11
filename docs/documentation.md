# Dokumentasi Teknis — Customer Analytics Pipeline

Dokumen ini berisi detail teknis pendukung: data dictionary, definisi metodologi, daftar DAX measures, dan asumsi yang digunakan dalam project. Untuk ringkasan project dan insight bisnis, lihat [README.md](../README.md) di root repository.

---

## 1. Data Dictionary

### 1.1 Tabel `clean_transactions.csv`
Level: **transaksi** (1 baris = 1 baris item dalam sebuah invoice)

| Kolom | Tipe Data | Deskripsi |
|---|---|---|
| `InvoiceNo` | Text | Nomor invoice/transaksi. Unik per transaksi, tapi satu invoice bisa punya banyak baris (multi-item) |
| `StockCode` | Text | Kode unik produk |
| `Description` | Text | Nama/deskripsi produk |
| `Quantity` | Integer | Jumlah unit yang dibeli dalam baris transaksi tersebut (selalu > 0 setelah cleaning) |
| `InvoiceDate` | Timestamp | Tanggal dan waktu transaksi terjadi |
| `UnitPrice` | Double | Harga per unit produk (dalam GBP, selalu > 0 setelah cleaning) |
| `CustomerID` | Integer | ID unik pelanggan |
| `Country` | Text | Negara asal pelanggan |
| `TotalPrice` | Double | Hasil kalkulasi `Quantity × UnitPrice` |

### 1.2 Tabel `master_customer_analytics.csv`
Level: **pelanggan** (1 baris = 1 pelanggan unik)

| Kolom | Tipe Data | Deskripsi |
|---|---|---|
| `CustomerID` | Integer | ID unik pelanggan (primary key) |
| `Recency` | Integer | Jumlah hari sejak transaksi terakhir pelanggan, dihitung relatif terhadap tanggal transaksi terakhir di dataset (2011-12-09) |
| `Frequency` | Integer | Jumlah invoice unik (transaksi) yang pernah dilakukan pelanggan |
| `Monetary` | Double | Total nilai transaksi historis pelanggan (GBP) |
| `R_Score` | Integer (1-5) | Skor Recency hasil `NTILE(5)`. Skor 5 = paling baru bertransaksi |
| `F_Score` | Integer (1-5) | Skor Frequency hasil `NTILE(5)`. Skor 5 = paling sering bertransaksi |
| `M_Score` | Integer (1-5) | Skor Monetary hasil `NTILE(5)`. Skor 5 = nilai transaksi terbesar |
| `RFM_Segment_Code` | Text | Gabungan tiga skor (contoh: `"545"` = R_Score 5, F_Score 4, M_Score 5) |
| `Segment` | Text | Label segmen bisnis hasil pemetaan `RFM_Segment_Code` (lihat Bagian 2) |
| `AOV` | Double | Average Order Value = `Monetary / Frequency` |
| `Monthly_Purchase_Rate` | Double | Estimasi frekuensi transaksi per bulan = `Frequency / (Tenure_Days floor 30 hari / 30)` |
| `Predicted_CLV` | Double | Proyeksi nilai pelanggan 12 bulan ke depan (lihat Bagian 3) |
| `Tenure_Days` | Integer | Jumlah hari antara transaksi pertama dan terakhir pelanggan |
| `Churn_Status` | Text | `"Churned"` jika Recency > 90 hari, selain itu `"Active"` |

---

## 2. Metodologi RFM Segmentation

### 2.1 Perhitungan Skor
Setiap dimensi RFM diberi skor 1-5 menggunakan fungsi window `NTILE(5)`, membagi seluruh populasi pelanggan ke dalam 5 kelompok berukuran sama (quintile):

| Dimensi | Arah Urutan | Alasan |
|---|---|---|
| Recency | `ORDER BY Recency DESC` | Nilai Recency kecil (baru beli) harus dapat skor tinggi, sehingga urutan dibalik |
| Frequency | `ORDER BY Frequency ASC` | Nilai Frequency besar (sering beli) mendapat skor tinggi secara alami |
| Monetary | `ORDER BY Monetary ASC` | Nilai Monetary besar (belanja banyak) mendapat skor tinggi secara alami |

### 2.2 Logika Pemetaan Segmen

| Segmen | Kriteria |
|---|---|
| Champions | R≥4, F≥4, M≥4 |
| Loyal Customers | R≥3, F≥3, M≥3 |
| New Customers | R≥4, F≤2 |
| Potential Loyalist | R≥3, F≤2, M≤2 |
| At Risk | R≤2, F≥4, M≥4 |
| Cant Lose Them | R≤2, F≥3 |
| Hibernating | R≤2, F≤2, M≤2 |
| Lost | R≤1, F≤1 |
| Others | Kombinasi yang tidak masuk kategori di atas |

**Catatan:** Segmen "Others" adalah *catch-all* untuk kombinasi skor yang tidak terpetakan secara eksplisit oleh aturan di atas. Pada dataset ini, segmen tersebut mewakili ~10.5% populasi pelanggan. Threshold dapat disesuaikan lebih lanjut jika ingin memperkecil proporsi "Others".

---

## 3. Metodologi Customer Lifetime Value (CLV)

### 3.1 Formula
```
Predicted CLV = Average Order Value × Monthly Purchase Rate × Estimated Lifespan (bulan)
```
Dengan:
- **Average Order Value (AOV)** = `Monetary / Frequency`
- **Monthly Purchase Rate** = `Frequency / (Tenure_Days / 30)`
- **Estimated Lifespan** = 12 bulan (asumsi tetap, lihat Bagian 5)

### 3.2 Penanganan Edge Case: Tenure Sangat Pendek
Pelanggan dengan `Tenure_Days` sangat kecil (misalnya melakukan beberapa transaksi hanya dalam 1-2 hari) menyebabkan `Monthly_Purchase_Rate` menjadi sangat besar jika dihitung langsung (*division by near-zero*), sehingga `Predicted_CLV` menjadi tidak realistis (dapat mencapai jutaan GBP untuk satu pelanggan).

**Solusi yang diterapkan:** `Tenure_Days` diberi nilai lantai (floor) minimum 30 hari menggunakan `GREATEST(Tenure_Days, 30)` sebelum digunakan sebagai pembagi. Ini adalah pendekatan umum di industri untuk mencegah distorsi akibat pelanggan dengan histori transaksi sangat pendek.

### 3.3 Keterbatasan
Model CLV ini adalah **pendekatan heuristik sederhana** (bukan model statistik seperti BG/NBD atau Gamma-Gamma), sehingga:
- Rata-rata (`AVG`) CLV per segmen dapat terpengaruh outlier ekstrem (contoh: segmen "Lost" pada dataset ini memiliki rata-rata CLV yang lebih tinggi dari ekspektasi karena satu-dua pelanggan dengan frekuensi tinggi dalam periode sangat singkat). Untuk gambaran representatif per segmen, disarankan melihat **Total Predicted CLV**, bukan hanya rata-rata.
- Model ini tidak memperhitungkan tren musiman, diskon, retensi produk, atau churn probability secara eksplisit.

---

## 4. Definisi Churn

Pelanggan diklasifikasikan sebagai **"Churned"** apabila `Recency > 90 hari` (tidak melakukan transaksi apa pun dalam 90 hari terakhir, dihitung relatif terhadap tanggal transaksi terakhir dalam dataset).

Threshold 90 hari dipilih sebagai standar umum untuk retail non-subscription. Threshold ini bersifat dapat disesuaikan (*configurable*) tergantung siklus pembelian rata-rata bisnis yang dianalisis — pada dataset ini, rata-rata tenure pelanggan adalah ~203 hari, sehingga 90 hari dianggap representatif sebagai titik "belum tentu churn, tapi mulai berisiko".

---

## 5. Asumsi & Batasan (Assumptions & Limitations)

1. **Reference date** untuk perhitungan Recency menggunakan tanggal transaksi terakhir dalam dataset (2011-12-09), bukan tanggal hari ini — karena dataset bersifat historis (data 2010-2011).
2. **Estimated Lifespan** untuk CLV ditetapkan tetap 12 bulan sebagai simplifikasi; pada implementasi produksi, nilai ini idealnya diturunkan dari analisis survival/cohort yang lebih mendalam.
3. **Threshold churn (90 hari)** adalah asumsi tetap, bukan hasil optimasi statistik terhadap data historis churn aktual.
4. Dataset hanya mencakup transaksi online non-store dari satu perusahaan grosir/retail UK, sehingga generalisasi ke industri lain perlu kehati-hatian.
5. Baris dengan `CustomerID` kosong (~24.9% dari data mentah) tidak dapat diikutsertakan dalam analisis level pelanggan karena tidak dapat diatribusikan ke pelanggan mana pun — ini merupakan keterbatasan bawaan dataset, bukan pilihan metodologi.

---

## 6. DAX Measures (Power BI)

Seluruh measure berikut dibuat pada tabel `master_customer_analytics`, kecuali disebutkan lain.

```dax
Total Revenue = SUM(clean_transactions[TotalPrice])
```
```dax
Total Customers = DISTINCTCOUNT(master_customer_analytics[CustomerID])
```
```dax
Total Orders = DISTINCTCOUNT(clean_transactions[InvoiceNo])
```
```dax
Avg Order Value = DIVIDE([Total Revenue], [Total Orders])
```
```dax
Churned Customers = 
CALCULATE(
    DISTINCTCOUNT(master_customer_analytics[CustomerID]),
    master_customer_analytics[Churn_Status] = "Churned"
)
```
```dax
Churn Rate % = DIVIDE([Churned Customers], [Total Customers]) * 100
```
```dax
Active Customers = [Total Customers] - [Churned Customers]
```
```dax
Total Predicted CLV = SUM(master_customer_analytics[Predicted_CLV])
```
```dax
Avg Predicted CLV = AVERAGE(master_customer_analytics[Predicted_CLV])
```
```dax
Revenue at Risk = 
CALCULATE(
    SUM(master_customer_analytics[Monetary]),
    master_customer_analytics[Churn_Status] = "Churned"
)
```

**Catatan implementasi penting:** relationship antara `master_customer_analytics` dan `clean_transactions` (dihubungkan melalui `CustomerID`) harus diatur dengan **Cross filter direction: Both**. Tanpa ini, visual yang memfilter berdasarkan kolom di `clean_transactions` (misalnya `Country`) tidak akan ikut memfilter measure yang dihitung dari `master_customer_analytics` (misalnya `Total Predicted CLV`), sehingga menghasilkan angka yang salah/seragam pada seluruh kategori.

---

## 7. Struktur Data Pipeline (Ringkas)

```
raw_transactions          (541,909 baris, semua kolom VARCHAR)
        ↓ cleaning & type casting
clean_transactions        (397,884 baris, tipe data final)
        ↓ aggregation per CustomerID
rfm_base                  (4,338 baris: Recency, Frequency, Monetary)
        ↓ NTILE(5) scoring
rfm_scored                (+ R_Score, F_Score, M_Score)
        ↓ CASE WHEN mapping
rfm_segmented              (+ RFM_Segment_Code, Segment)
        ↓ join dengan customer_tenure
clv_analysis               (+ AOV, Monthly_Purchase_Rate, Predicted_CLV)
        ↓ CASE WHEN Recency > 90
churn_analysis              (+ Churn_Status)
        ↓ join semua tabel di atas
master_customer_analytics  (tabel final, 4,338 baris)
```

Detail query SQL lengkap tersedia di [`sql/customer_analytics_pipeline.sql`](../sql/customer_analytics_pipeline.sql), atau jalankan otomatis melalui [`scripts/run_pipeline.py`](../scripts/run_pipeline.py).
