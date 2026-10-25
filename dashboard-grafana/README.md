# Dashboard Grafana

File dashboard Grafana sẵn để import tay, không cần chạy script.

| File | Nội dung |
|---|---|
| `proxmox-cluster-dashboard.json` | Dashboard "Proxmox Cluster": tổng quan node, CPU/RAM, VM và nhóm panel NIC (link, lỗi, `ip -s link`, `ethtool -S`) |

## Import

1. Grafana → **Dashboards → New → Import → Upload dashboard JSON file** → chọn `proxmox-cluster-dashboard.json`.
2. Đổi **Name** và **UID** nếu muốn import nhiều cluster vào cùng một Grafana, rồi bấm **Import**.
3. Trên dashboard, chọn ở thanh trên cùng:
   - **Datasource**: datasource InfluxDB (Flux) của cluster.
   - **Bucket**: bucket mà Proxmox Metric Server ghi vào.
   - **Server**: node cần xem.

Mọi panel dùng biến `${dsProxmox}`, không gắn cứng datasource, nên dùng được với mọi Grafana.

> Muốn dashboard tự chọn đúng bucket/datasource của cluster, dùng lệnh `./deploy-monitor-nic-proxmox.sh dashboard` trong thư mục `deploy/` (xem [README chính](../README.md#63-import-dashboard)).

## Yêu cầu

- Grafana 10 trở lên (đã kiểm tra trên Grafana 13).
- Datasource InfluxDB 2.x, ngôn ngữ truy vấn **Flux**.
- Các node đã cài module thu thập (`deploy/`), để có measurement `nics` và `system`.
