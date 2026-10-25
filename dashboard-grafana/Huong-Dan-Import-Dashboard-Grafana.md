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

Tạo token Grafana: **Administration → Users and access → Service accounts → Add service account** (role **Editor**) → **Add service account token**.

```bash
cd /root/nic-monitor/dashboard-grafana

# Script hỏi lần lượt URL, token, datasource, bucket
bash import-dashboard.sh

# Hoặc truyền sẵn, không hỏi
bash import-dashboard.sh -u https://10.0.0.5:3000 -t 'glsa_xxx' -d 'InfluxDB-Proxmox' -b proxmox-demo -f Proxmox -y
```

| Tùy chọn | Biến môi trường | Ý nghĩa |
|---|---|---|
| `-u URL` | `GRAFANA_URL` | URL Grafana, HTTPS tự ký vẫn dùng được |
| `-t TOKEN` | `GRAFANA_TOKEN` | Token service account |
| `-d TÊN` | `GRAFANA_DS` | Tên datasource InfluxDB. Bỏ trống: chỉ có 1 thì tự chọn, nhiều thì hỏi |
| `-b BUCKET` | `BUCKET` | Bucket của cluster. Chạy trên node Proxmox thì tự đọc từ `/etc/pve/status.cfg` |
| `-f FOLDER` | `GRAFANA_FOLDER` | Thư mục Grafana lưu dashboard, chưa có thì tự tạo |
| `-o FILE` | | File JSON đầu ra (mặc định `dashboard-<bucket>.json`) |
| `--no-import` | | Chỉ tạo file JSON, không gọi Grafana |
| `-y` | | Không hỏi gì |

Kết quả mẫu:

```
[OK] Ket noi Grafana: https://10.0.0.5:3000
[OK] Datasource: InfluxDB-Proxmox
[OK] Bucket lay tu /etc/pve/status.cfg: proxmox-demo
[OK] Da tao .../dashboard-grafana/dashboard-proxmox-demo.json
[OK] Da import vao Grafana: https://10.0.0.5:3000/d/pve-nic-proxmox-demo/proxmox-cluster-proxmox-demo
```

Mỗi bucket có title `Proxmox Cluster <bucket>` và UID riêng (`pve-nic-<bucket>`), nên nhiều cluster dùng chung một Grafana không ghi đè nhau. Chạy lại lệnh sẽ cập nhật đúng dashboard đó.

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
| `Token khong hop le hoac thieu quyen` | Tạo lại token, service account cần role **Editor** |
| `Khong co datasource InfluxDB ten '...'` | Kiểm tra tên ở **Connections → Data sources**, hoặc bỏ `-d` để chọn từ danh sách |
| Dashboard trống | Chọn đúng Datasource/Bucket/Server, thời gian **Last 15 minutes**; chạy `bash deploy/deploy-monitor-nic-proxmox.sh diag -f deploy/nodes.txt` |
