# Hướng Dẫn Import Dashboard Grafana

Dashboard **Proxmox Cluster**: tổng quan node, CPU/RAM, VM và nhóm panel NIC (trạng thái link, lỗi, `ip -s link`, `ethtool -S`).

| File | Nội dung |
|---|---|
| `proxmox-cluster-dashboard.json` | Dashboard mẫu, file duy nhất trong repo |
| `import-dashboard.sh` | Tạo dashboard đúng bucket/datasource và import vào Grafana bằng 1 lệnh |
| `export-dashboard.sh` | Lấy dashboard đang chạy trên Grafana về repo sau khi sửa giao diện |

## Yêu cầu

- Grafana 10 trở lên (đã kiểm tra trên Grafana 13).
- Datasource InfluxDB 2.x, ngôn ngữ truy vấn **Flux**, trỏ tới bucket mà Proxmox Metric Server ghi vào.
- Các node đã cài module thu thập (`install.sh` hoặc `deploy/`), để có measurement `nics` và `system`.
- Chạy script: `bash`, `curl`, `python3` (node Proxmox có sẵn).

## Cách 1: Import bằng script (khuyên dùng)

Chuẩn bị:

- **Token InfluxDB** có quyền đọc bucket của cluster (InfluxDB UI → **Load Data → API Tokens**).
- **Token Grafana**: **Administration → Users and access → Service accounts → Add service account** → **Add service account token**. Role **Admin** nếu muốn script tự tạo datasource; role **Editor** chỉ đủ khi dùng datasource có sẵn.

```bash
cd /root/nic-monitor/dashboard-grafana
bash import-dashboard.sh
```

Script hỏi lần lượt, mục nào có giá trị sẵn thì hiện trong `[ ]` (Enter để giữ), token nhập ẩn. Nhập sai thì báo lỗi và cho nhập lại:

| Bước | Hỏi | Script làm gì |
|---|---|---|
| 1. InfluxDB | URL, Organization, Bucket, Token | Kiểm tra kết nối, token, org và bucket có tồn tại. Chạy trên node Proxmox thì mặc định lấy từ Metric Server |
| 2. Grafana | URL, Token | Kiểm tra kết nối và quyền của token |
| 3. Datasource | Chọn số | Liệt kê datasource InfluxDB, đánh dấu cái **khớp URL + org** ở bước 1. Chọn `0` để **tạo datasource mới** (Flux, đúng org/bucket/token) với tên do bạn đặt. Sau đó kiểm tra datasource truy vấn được InfluxDB |
| 4. Tên dashboard | Tên | UID tạo từ tên (`Proxmox Cluster HCM` → `pve-proxmox-cluster-hcm`). Đã có dashboard cùng UID thì hỏi trước khi ghi đè |
| 5. Import | | Import qua API, in đường dẫn dashboard |

Chạy không hỏi (truyền sẵn tất cả):

```bash
bash import-dashboard.sh -y -i http://10.0.0.5:8086 -O myorg -b proxmox-demo -k '<token-influx>'     -u https://10.0.0.5:3000 -t 'glsa_xxx' -n 'Proxmox Cluster HCM' -f Proxmox
```

| Tùy chọn | Biến môi trường | Ý nghĩa |
|---|---|---|
| `-i URL` | `INFLUX_URL` | URL InfluxDB 2.x |
| `-O ORG` | `INFLUX_ORG` | Organization InfluxDB |
| `-b BUCKET` | `INFLUX_BUCKET` | Bucket Proxmox ghi vào |
| `-k TOKEN` | `INFLUX_TOKEN` | Token InfluxDB |
| `-u URL` | `GRAFANA_URL` | URL Grafana, HTTPS tự ký vẫn dùng được |
| `-t TOKEN` | `GRAFANA_TOKEN` | Token service account Grafana |
| `-d TÊN` | `GRAFANA_DS` | Dùng datasource có sẵn tên này. Bỏ trống: tìm datasource khớp URL + org, không có thì tạo mới |
| `-n TÊN` | `DASH_TITLE` | Tên dashboard (mặc định `Proxmox Cluster <bucket>`) |
| `-f FOLDER` | `GRAFANA_FOLDER` | Thư mục Grafana lưu dashboard, chưa có thì tự tạo |
| `-o FILE` | | File JSON đầu ra (mặc định `dashboard-<tên>.json`) |
| `--no-import` | | Chỉ tạo file JSON, không gọi Grafana (chỉ cần bucket và tên) |
| `-y` | | Không hỏi gì |

Mỗi dashboard có UID riêng theo tên, nên nhiều cluster dùng chung một Grafana không ghi đè nhau. Chạy lại với cùng tên sẽ cập nhật đúng dashboard đó.

## Cách 2: Import tay

1. Grafana → **Dashboards → New → Import → Upload dashboard JSON file** → chọn `proxmox-cluster-dashboard.json`.
2. Đổi **Name** và **UID** nếu import nhiều cluster vào cùng một Grafana, rồi bấm **Import**.
3. Trên dashboard, chọn ở thanh trên cùng:
   - **Datasource**: datasource InfluxDB (Flux) của cluster.
   - **Bucket**: bucket mà Proxmox Metric Server ghi vào.
   - **Server**: node cần xem.

Mọi panel dùng biến `${dsProxmox}`, không gắn cứng datasource, nên dùng được với mọi Grafana.

## Cập nhật dashboard mẫu sau khi sửa giao diện

Sửa dashboard trực tiếp trên Grafana, xong lấy về repo:

```bash
cd /root/nic-monitor/dashboard-grafana
bash export-dashboard.sh -u https://10.0.0.5:3000 -t 'glsa_xxx' -i <uid-dashboard>
git add proxmox-cluster-dashboard.json && git commit -m "Cap nhat dashboard" && git push
```

`<uid-dashboard>` là phần sau `/d/` trên URL, ví dụ `.../d/adpmac64/proxmox-cluster-demo` → `adpmac64`. Script tự làm sạch: bỏ `id`/`version`, đổi datasource về `${dsProxmox}`, xóa bucket/datasource/node đang chọn, đặt title `Proxmox Cluster`.

## Xử lý lỗi

| Thông báo | Cách xử lý |
|---|---|
| `Khong ket noi duoc Grafana` | Sai URL/port, hoặc máy chạy script không tới được Grafana |
| `InfluxDB tu choi (sai token hoac org ...)` | Kiểm tra token InfluxDB và tên organization (InfluxDB UI → Load Data → API Tokens) |
| `Org '...' khong co bucket '...'` | Sai tên bucket, hoặc token không có quyền đọc bucket đó |
| `Token Grafana khong hop le hoac thieu quyen` | Tạo lại token service account (role **Editor** trở lên) |
| `Khong tao duoc datasource` | Trùng tên datasource (đặt tên khác), hoặc token Grafana chưa có role **Admin** |
| `Datasource ... chua truy van duoc InfluxDB` | Máy chủ Grafana không tới được URL InfluxDB; sửa URL trong **Connections → Data sources** |
| `Khong co datasource InfluxDB ten '...'` | Kiểm tra tên ở **Connections → Data sources**, hoặc bỏ `-d` để chọn từ danh sách |
| Dashboard trống | Chọn đúng Datasource/Bucket/Server, thời gian **Last 15 minutes**; chạy `bash deploy/deploy-monitor-nic-proxmox.sh diag -f deploy/nodes.txt` |
