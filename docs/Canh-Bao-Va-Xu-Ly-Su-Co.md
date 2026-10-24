# Cảnh báo, xử lý sự cố và vận hành

Tài liệu bổ sung cho [Hướng dẫn triển khai](Huong-Dan-Trien-Khai.md). Trong các truy vấn mẫu, thay `proxmox-cluster-deco` bằng bucket của cluster bạn.

## 1. Cảnh báo (Grafana Alerting)

Tạo trong **Alerting → Alert rules → New alert rule**, datasource InfluxDB (Flux). Nên có hai cảnh báo sau.

### a) Card 10G mất link

```flux
from(bucket: "proxmox-cluster-deco")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "nics")
  |> filter(fn: (r) => r._field == "network_up" or r._field == "link_speed_max")
  |> last()
  |> keep(columns: ["host", "instance", "_field", "_value"])
  |> group(columns: ["host", "instance"])
  |> pivot(rowKey: ["host", "instance"], columnKey: ["_field"], valueColumn: "_value")
  |> filter(fn: (r) => exists r.link_speed_max and r.link_speed_max >= 10000.0)
  |> map(fn: (r) => ({ host: r.host, instance: r.instance, _time: now(),
                      _value: if exists r.network_up then r.network_up else 0.0 }))
  |> group(columns: ["host", "instance"])
```

Điều kiện: **Reduce** Last, **Threshold** IS BELOW 1, **Pending period** 1m.

### b) Lỗi CRC / RX errors đang tăng

```flux
from(bucket: "proxmox-cluster-deco")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "nics")
  |> filter(fn: (r) => r._field == "rx_crc_errors" or r._field == "rx_errors" or r._field == "ethtool_port_rx_crc_errors")
  |> filter(fn: (r) => r.instance !~ /^(lo|tap.*|veth.*|fwbr.*|fwpr.*|fwln.*|vmbr.*|bond.*)$/)
  |> group(columns: ["host", "instance", "_field"])
  |> difference(nonNegative: true)
  |> sum()
```

Điều kiện: **Reduce** Last, **Threshold** IS ABOVE 0 (hoặc ngưỡng lớn hơn, ví dụ 10, để tránh báo vì lỗi lẻ tẻ). Nhãn `host`, `instance` có sẵn trong cảnh báo để biết node và card nào lỗi.

> Hai truy vấn trên là mẫu. Hãy bấm **Preview** trong Alert rule để chạy thử trước khi bật gửi thông báo.

## 2. Ý nghĩa các loại lỗi card mạng

| Hiện tượng | Nguyên nhân thường gặp | Hướng xử lý |
|---|---|---|
| `rx_crc_errors`, `rx_length_errors`, `port.rx_crc_errors` tăng | Lỗi lớp vật lý: cáp/DAC hỏng, SFP bẩn hoặc lỗi, port switch lỗi, không khớp tốc độ/FEC | Vệ sinh hoặc thay SFP, thay cáp/DAC, đổi port switch, xem counter lỗi phía switch |
| `rx_dropped` tăng nhưng không có errors | Kernel bỏ gói ở tầng phần mềm: VLAN chưa cấu hình, protocol không xử lý (LLDP…), gói không có đích | Thường không nghiêm trọng. Nếu tăng nhanh thì xem thêm `rx_missed_errors` / `rx_fifo_errors` |
| `rx_missed_errors`, `rx_fifo_errors`, `rx_over_errors` tăng | Ring buffer đầy, CPU xử lý ngắt không kịp | Xem `ethtool -g <if>`, tăng ring: `ethtool -G <if> rx 4096`. Kiểm tra CPU/IRQ |
| `tx_dropped`, `port.tx_dropped_link_down` tăng | Link chập chờn (flapping), hàng đợi gửi đầy | Xem panel UP/DOWN và log switch, kiểm tra cáp/SFP |
| `tx_carrier_errors` tăng | Mất tín hiệu khi đang gửi | Kiểm tra cáp, SFP, port switch |
| `collisions` khác 0 | Link đang half-duplex | Kiểm tra duplex, ép full-duplex ở cả hai đầu |
| Card 10G hiện `UP 1G` (màu cam) | SFP 1G, cáp không đạt chuẩn, port switch cấu hình 1G, auto-negotiation sai | Xem `ethtool <if>`, kiểm tra loại module và cấu hình port switch |
| `udp_loss` tăng | Gói UDP bị mất ở node, ảnh hưởng Corosync | Kiểm tra mạng Corosync, tải CPU, `rx_missed_errors` của card chạy Corosync |

### Quy trình xử lý khi thấy lỗi CRC

1. Trên dashboard, xác định node, card và thời điểm lỗi tăng (biểu đồ "tăng mỗi chu kỳ").
2. Trên node, xác nhận lỗi còn tăng: chạy `ethtool -S <if> | grep crc` hai lần cách nhau 1 phút.
3. Xem thông tin module quang: `ethtool -m <if>` (nhiệt độ, công suất thu/phát nếu SFP hỗ trợ).
4. Kiểm tra counter lỗi tương ứng trên port switch. Lỗi CRC thường chỉ thấy ở phía nhận.
5. Xử lý theo thứ tự: vệ sinh đầu quang → thay dây/DAC → thay SFP → đổi port switch.
6. Sau khi xử lý, theo dõi biểu đồ: không còn cột tăng mới là đã khắc phục.

## 3. Sự cố khi triển khai

| Hiện tượng | Nguyên nhân | Cách khắc phục |
|---|---|---|
| Panel 10G hiện "Chua co du lieu link_speed" | Chưa cài bản mới, hoặc `pvestatd` chưa restart | Chạy `./deploy-monitor-nic-proxmox.sh install` rồi `check` |
| Dữ liệu ngừng sau khi `apt upgrade` | Nâng cấp `pve-manager` đã ghi đè `InfluxDB.pm`, mất patch | Chạy lại `./deploy-monitor-nic-proxmox.sh install -f nodes.txt` |
| Không có field `ethtool_*` | Thiếu `ethtool`, hoặc card không phải card vật lý | `apt install ethtool` rồi chạy lại `install` |
| Card 10G không hiện trên panel 10G | Driver không báo link mode và card DOWN từ khi `pvestatd` khởi động | Chạy `ethtool <if>` để xem; card sẽ hiện khi có link lần đầu |
| `[LOI] InfluxDB.pm sau khi patch bi loi cu phap` | Phiên bản `InfluxDB.pm` có cấu trúc khác | Script không ghi đè nên node vẫn an toàn. Cài thủ công theo [Cai-Dat-Thu-Cong.md](Cai-Dat-Thu-Cong.md) |
| `khong thay diem chen trong update_node_status` | Hàm `update_node_status` khác cấu trúc mong đợi | Như trên, node không bị thay đổi |
| `[LOI] Khong copy duoc file len` | Sai IP, node tắt, chưa có SSH key | Kiểm tra `ssh root@<ip> hostname` |
| `Permission denied` | Chưa copy SSH key, sai `SSH_PASS` | Chạy `ssh-copy-id`, hoặc kiểm tra biến `SSH_PASS` |
| `$'\r': command not found` | Script bị đổi sang CRLF khi copy qua Windows | `sed -i 's/\r$//' deploy-monitor-nic-proxmox.sh CustomNetworkMetrics.pm` |
| `journalctl` báo "Loi khi thu thap advanced network metrics" | Lỗi khi module đọc số liệu (hiếm) | Module bắt lỗi nên `pvestatd` vẫn chạy. Xem nội dung lỗi trong log |
| Dashboard trống toàn bộ | Sai datasource/bucket, hoặc Metric Server bị tắt | Kiểm tra Metric Server và biến Datasource/Bucket trên dashboard. Chạy `diag` |

## 4. Vận hành và bảo trì

### Sau khi nâng cấp Proxmox

Mỗi lần `apt upgrade` có nâng cấp gói `pve-manager`, file `InfluxDB.pm` bị ghi đè và mất patch. Dấu hiệu: các panel NIC không còn dữ liệu mới, trong khi panel CPU/RAM vẫn bình thường.

```bash
./deploy-monitor-nic-proxmox.sh check -f nodes.txt     # node nào báo [THIEU] là đã mất patch
./deploy-monitor-nic-proxmox.sh install -f nodes.txt
```

Chạy lại `install` luôn an toàn: không chèn trùng, không ghi đè bản backup `.bak`.

### Thêm node mới vào cluster

1. Thêm IP node mới vào `nodes.txt`.
2. Nếu dùng SSH key: `ssh-copy-id root@<ip-node-moi>`.
3. Chạy `./deploy-monitor-nic-proxmox.sh install <ip-node-moi>`.
4. Trên dashboard, node mới tự xuất hiện trong biến **Server**.

### Sửa module

Sửa `CustomNetworkMetrics.pm`, kiểm tra cú pháp bằng `perl -c CustomNetworkMetrics.pm`, rồi chạy lại `install`. Phần patch `InfluxDB.pm` giữ nguyên.

### Timeout gửi dữ liệu

Nếu `journalctl -u pvestatd` báo timeout khi gửi sang InfluxDB, tăng timeout trong **Datacenter → Metric Server → Edit**. Không nên tự nối dòng vào `/etc/pve/status.cfg`, vì file có thể chứa nhiều metric server.

### Dung lượng dữ liệu

Mỗi card vật lý có khoảng 25 field kernel cộng 10–20 field ethtool, gửi 10 giây/lần. Card ảo của VM không có bộ đếm lỗi, nên số series tăng thêm không đáng kể so với dữ liệu sẵn có của Proxmox. Dung lượng thực tế phụ thuộc chính sách retention của bucket.

### Kiểm tra định kỳ

| Tần suất | Việc cần làm |
|---|---|
| Hằng ngày | Xem panel "Physical NIC Link Status (10G+)" và các biểu đồ "tăng mỗi chu kỳ" |
| Hằng tuần | Xem bảng counter tích lũy, đối chiếu card có lỗi tăng dần |
| Sau mỗi lần nâng cấp Proxmox | `./deploy-monitor-nic-proxmox.sh check -f nodes.txt`, cài lại nếu mất patch |
| Sau khi thay cáp/SFP | Theo dõi biểu đồ lỗi ít nhất 24 giờ để xác nhận đã hết |

### Gỡ thủ công trên 1 node

```bash
apt-get install --reinstall pve-manager
grep -c CustomNetworkMetrics /usr/share/perl5/PVE/Status/InfluxDB.pm   # phải ra 0
rm -f /usr/share/perl5/PVE/CustomNetworkMetrics.pm
systemctl restart pvestatd
```

Sau khi gỡ, các panel NIC không còn dữ liệu mới. Dữ liệu cũ vẫn nằm trong InfluxDB theo retention của bucket.

## 5. Checklist triển khai

| # | Hạng mục | Cách kiểm tra | Đạt |
|---|---|---|---|
| 1 | Metric Server InfluxDB đang hoạt động | Dashboard có số liệu CPU/RAM | ☐ |
| 2 | SSH key tới mọi node | `ssh root@<ip> hostname` không hỏi mật khẩu | ☐ |
| 3 | Đã khai báo `nodes.txt` | Đủ IP các node | ☐ |
| 4 | Script là LF, có quyền chạy | `file deploy-monitor-nic-proxmox.sh` không có CRLF | ☐ |
| 5 | Ghi lại số liệu gốc của card cần theo dõi | `ip -s link`, `ethtool -S` | ☐ |
| 6 | Cài thử 1 node thành công | Output toàn `[OK]` | ☐ |
| 7 | Dashboard đúng bucket đã import | Panel NIC có số liệu | ☐ |
| 8 | Cài toàn cluster | `check -f nodes.txt` mọi node `[OK]` | ☐ |
| 9 | Cảnh báo đã tạo và Preview chạy đúng | Alert rule có dữ liệu | ☐ |
