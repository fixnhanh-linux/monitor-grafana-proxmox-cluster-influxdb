# Kiểm tra thủ công dữ liệu trên dashboard

Tài liệu này giúp tự đối chiếu: **số liệu trên dashboard có đúng với thực tế trên node không**. Mỗi mục gồm lệnh chạy trên node (bằng root) để lấy số liệu gốc, giá trị tương ứng trên dashboard và khi nào coi là khớp.

Dữ liệu đi qua 3 tầng, kiểm tra lần lượt để biết sai ở đâu:

```
Lệnh gốc trên node  ->  Module gửi đi (pvestatd)  ->  InfluxDB  ->  Dashboard Grafana
   (mục 2 - 6)              (mục 1)                  (mục 7)       (mục 8)
```

- Lệnh gốc khớp module, nhưng InfluxDB không có: lỗi gửi dữ liệu (chạy lệnh `diag`).
- InfluxDB có, nhưng dashboard sai hoặc trống: chọn sai Datasource / Bucket / Server, hoặc khoảng thời gian.

Trong các ví dụ, thay `pve1`, `nic0`, `vlan3001`, `10.80.55.101` bằng tên node, card, interface và IP thật của bạn.

---

## 1. Xem module đang gửi gì

Module chạy trong `pvestatd` và gửi số liệu 10 giây/lần. Chạy thử module để xem đúng những giá trị đang được gửi sang InfluxDB:

```bash
# Số liệu hệ thống + Corosync (measurement "system")
perl -I/usr/share/perl5 -MPVE::CustomNetworkMetrics -MData::Dumper -e \
  '$Data::Dumper::Sortkeys = 1; print Dumper(PVE::CustomNetworkMetrics::get_metrics()->{global})'

# Số liệu một card (measurement "nics"), ví dụ nic0
perl -I/usr/share/perl5 -MPVE::CustomNetworkMetrics -MData::Dumper -e \
  '$Data::Dumper::Sortkeys = 1; print Dumper(PVE::CustomNetworkMetrics::get_metrics()->{nics}{"nic0"})'
```

Hoặc dùng lệnh `check` (in gọn từng card và từng link Corosync):

```bash
bash /root/nic-monitor/deploy/deploy-monitor-nic-proxmox.sh check 127.0.0.1
```

Các mục 2 – 6 dưới đây so **giá trị trong output này** với **lệnh gốc**.

---

## 2. Corosync Links / Corosync Link Health

### 2.1. Trạng thái từng link

```bash
corosync-cfgtool -s
```

Kết quả mẫu (node 1, cluster 3 node, 2 link):

```
LINK ID 0 udp
        addr    = 10.30.1.11
        status:
                nodeid:          1:     localhost
                nodeid:          2:     connected
                nodeid:          3:     connected
LINK ID 1 udp
        addr    = 10.80.55.101
        status:
                nodeid:          1:     localhost
                nodeid:          2:     disconnected
                nodeid:          3:     disconnected
```

| Trên dashboard | Lấy từ đâu trong output | Khớp khi |
|---|---|---|
| Ô `link0 …` = `✔ UP` | `LINK ID 0`: mọi `nodeid` (trừ `localhost`) là `connected` | Tất cả `connected` |
| Ô `link1 …` = `⛔ DOWN` | `LINK ID 1`: không `nodeid` nào `connected` | Tất cả `disconnected` |
| `▲ DEGRADED 1/2` | Có node `connected`, có node `disconnected` | Số `connected` / tổng node khác |
| Corosync Link Health = 100% / 0% | Số `connected` / số node khác × 100 | Ví dụ 2/2 = 100%, 0/2 = 0% |
| Field `corosync_links` / `corosync_links_up` | Số dòng `LINK ID` / số link có mọi node `connected` | Cùng giá trị |

### 2.2. IP và interface của link

```bash
# IP mà corosync.conf khai báo cho từng node trên từng link
grep -E 'name:|ring[0-9]+_addr' /etc/pve/corosync.conf

# Interface nào trên node đang mang IP của link (ví dụ IP của link1)
ip -br addr | grep -w 10.80.55.101
```

| Trên dashboard | Khớp khi |
|---|---|
| `link0 · vlan3001 · …` | `ip -br addr \| grep -w <IP link0>` ra dòng của `vlan3001` |
| `link1 · 10.80.55.101 · no local IP` | `ip -br addr \| grep -w 10.80.55.101` **không ra dòng nào**: node chưa có interface mang IP này. Cần gán IP đó cho card dùng cho link1 |

### 2.3. Card vật lý và tốc độ của link

Dashboard ghi `vlan3001 → nic0+nic1 · 10G`. Đối chiếu card vật lý nằm dưới interface:

```bash
# Linux bridge / bond / VLAN: card nằm dưới qua các file lower_*
ls /sys/class/net/vlan3001/ | grep lower_
cat /proc/net/bonding/bond0 2> /dev/null | grep -E 'Slave Interface|MII Status|Speed'

# Open vSwitch (có ovs-system): bridge chứa interface, rồi các card trên bridge
ovs-vsctl iface-to-br vlan3001
ovs-vsctl list-ifaces vmbr0
ovs-appctl bond/show 2> /dev/null

# Tốc độ từng card (Mb/s)
ethtool nic0 | grep -E 'Speed|Link detected'
cat /sys/class/net/nic0/speed
```

| Trên dashboard | Khớp khi |
|---|---|
| `→ nic0+nic1` | Các card vật lý (có thư mục `/sys/class/net/<card>/device`) tìm được qua `lower_*` hoặc `ovs-vsctl list-ifaces` |
| `· 10G` | Tốc độ cao nhất trong các card đang UP: `Speed: 10000Mb/s` = 10G, `1000Mb/s` = 1G |

---

## 3. NIC Link Status / NIC Link Speed

```bash
# UP/DOWN của card
ip -br link show nic0

# Tốc độ hiện tại và tốc độ tối đa card hỗ trợ
ethtool nic0 | grep -E 'Speed|Link detected'
ethtool nic0 | sed -n '/Supported link modes/,/Supported pause/p'
```

| Trên dashboard | Lấy từ | Khớp khi |
|---|---|---|
| Tên `nic0 [25G]` | Số lớn nhất trong `Supported link modes` (ví dụ `25000baseSR/Full`) | 25000 = `[25G]` |
| `✔ UP 10G` | `Speed: 10000Mb/s` và bằng tốc độ tối đa | Cùng tốc độ |
| `▲ UP 10G (below max)` | `Speed` nhỏ hơn tốc độ tối đa (card 25G chạy 10G) | `Speed` < số trong `[ ]` |
| `⛔ DOWN` | `ip -br link` ghi `DOWN`, hoặc `Link detected: no` | Card mất link |
| NIC Link Speed (đường) | `cat /sys/class/net/nic0/speed` theo thời gian | Cùng giá trị Mb/s |

---

## 4. Bộ đếm lỗi (bảng Since Boot và biểu đồ Per Interval)

```bash
# Bộ đếm kernel (giống bảng "NIC Link & Traffic / RX Errors / TX Errors (Since Boot)")
ip -s link show nic0

# Bộ đếm của driver (bảng "Ethtool Counters")
ethtool -S nic0 | grep -Ei 'err|drop|discard|crc|miss|timeout|length'
```

| Trên dashboard | Lấy từ | Khớp khi |
|---|---|---|
| Cột RX Errors / RX Dropped / TX Dropped… (Since Boot) | Cột `errors`, `dropped`… của dòng `RX:` / `TX:` trong `ip -s link` | Bằng nhau, hoặc dashboard nhỏ hơn một chút (dashboard là giá trị của lần gửi gần nhất, tối đa 10 giây trước) |
| Ethtool Counters | Dòng tương ứng của `ethtool -S`. Trên dashboard tên bỏ tiền tố `ethtool_`, dấu chấm thành `_` (`port.rx_crc_errors` → `port_rx_crc_errors`) | Bằng nhau |
| Biểu đồ Per Interval | Hiệu số giữa 2 lần đọc | Xem cách đo bên dưới |

Kiểm tra biểu đồ "Per Interval" (số lỗi **mới** trong mỗi khoảng): đọc 2 lần cách nhau 60 giây rồi lấy hiệu.

```bash
a=$(cat /sys/class/net/nic0/statistics/rx_crc_errors); sleep 60; b=$(cat /sys/class/net/nic0/statistics/rx_crc_errors)
echo "rx_crc_errors moi trong 60 giay: $((b - a))"
```

Bằng 0 thì biểu đồ trong khoảng đó cũng phải phẳng ở 0.

---

## 5. UDP Packet Loss

```bash
grep '^Udp:' /proc/net/snmp
```

Kết quả có 2 dòng: dòng tên cột và dòng giá trị. Giá trị của cột `InErrors` là số trên dashboard (cộng dồn từ lúc boot).

```
Udp: InDatagrams NoPorts InErrors OutDatagrams ...
Udp: 1234567 12 0 1234000 ...
```

Ví dụ trên `InErrors = 0`, dashboard phải hiện `0`.

---

## 6. Kiểm tra nhanh tất cả trong một lần

Đoạn sau in song song **lệnh gốc** và **giá trị module** cho Corosync và mọi card vật lý, để so bằng mắt:

```bash
echo "===== corosync-cfgtool -s"; corosync-cfgtool -s
echo "===== Module (corosync_*)"
perl -I/usr/share/perl5 -MPVE::CustomNetworkMetrics -e '
  my $g = PVE::CustomNetworkMetrics::get_metrics()->{global};
  printf "  %-28s %s\n", $_, $g->{$_} for grep { /^corosync_|^udp_/ } sort keys %$g'
for n in $(ls -d /sys/class/net/*/device 2> /dev/null | cut -d/ -f5); do
  echo "===== $n"
  ip -br link show "$n"
  ethtool "$n" 2> /dev/null | grep -E 'Speed|Link detected'
  ip -s link show "$n" | sed -n '3,6p'
done
```

---

## 7. Kiểm tra dữ liệu đã vào InfluxDB

Lấy cấu hình InfluxDB từ Metric Server của Proxmox, rồi truy vấn thẳng InfluxDB (token không in ra màn hình):

```bash
ID=$(awk '/^influxdb:/ {print $2; exit}' /etc/pve/status.cfg)
cfg() { awk -v k="$1" '/^influxdb:/ {s=1; next} /^[a-z]+:/ {s=0} s && $1 == k {print $2; exit}' /etc/pve/status.cfg; }
URL="$(cfg influxdbproto)://$(cfg server):$(cfg port)"; ORG=$(cfg organization); BUCKET=$(cfg bucket)
TOKEN=$(cat /etc/pve/priv/metricserver/$ID.pw)
q() { curl -sk "$URL/api/v2/query?org=$ORG" -H "Authorization: Token $TOKEN" \
        -H 'Content-Type: application/vnd.flux' -H 'Accept: application/csv' --data "$1"; }

# Corosync + UDP của node này, giá trị mới nhất trong 5 phút
q "from(bucket:\"$BUCKET\") |> range(start:-5m)
   |> filter(fn:(r)=> r._measurement==\"system\" and r.host==\"$(hostname)\" and r._field =~ /^(corosync_|udp_)/)
   |> last() |> keep(columns:[\"_field\",\"_value\"]) |> group()"

# Trạng thái và lỗi của card nic0
q "from(bucket:\"$BUCKET\") |> range(start:-5m)
   |> filter(fn:(r)=> r._measurement==\"nics\" and r.host==\"$(hostname)\" and r.instance==\"nic0\")
   |> filter(fn:(r)=> r._field =~ /^(network_up|link_speed|link_speed_max|rx_errors|rx_crc_errors|rx_dropped|tx_dropped)$/)
   |> last() |> keep(columns:[\"_field\",\"_value\"]) |> group()"
```

- Có kết quả, khớp mục 1: dữ liệu đã vào InfluxDB đúng.
- Trống: dữ liệu chưa vào InfluxDB. Chạy `bash /root/nic-monitor/deploy/deploy-monitor-nic-proxmox.sh diag 127.0.0.1` để biết lỗi ở đâu.
- Nếu Metric Server đang dùng UDP (`influxdbproto` trống hoặc `udp`): không truy vấn được theo cách này, xem trên InfluxDB UI (Data Explorer).

---

## 8. Kiểm tra trên Grafana

1. Trên panel cần kiểm tra, bấm **⋮ → Inspect → Data**: xem bảng giá trị thật mà panel đang vẽ, so với mục 7.
2. Bấm **Inspect → Query**: xem truy vấn đã chạy và lỗi (nếu có).
3. Kiểm tra thanh trên cùng của dashboard: **Datasource** trỏ đúng InfluxDB/bucket (mục 7), **Server** đúng tên node (`hostname`), khoảng thời gian đủ dài (ví dụ **Last 15 minutes**).
4. Dashboard chỉ cập nhật sau mỗi lần gửi (10 giây) và theo nút làm mới của Grafana. Lệnh gốc vừa chạy có thể mới hơn dashboard vài giây.

| Hiện tượng | Nguyên nhân thường gặp |
|---|---|
| Lệnh gốc và module khớp, InfluxDB trống | Lỗi gửi: sai token/bucket, timeout, mạng. Chạy lệnh `diag` |
| InfluxDB có, dashboard trống | Sai Datasource / Bucket / Server, hoặc khoảng thời gian quá ngắn |
| Dashboard chậm hơn lệnh gốc vài giây | Bình thường (chu kỳ gửi 10 giây) |
| Bộ đếm trên dashboard thấp hơn nhiều so với `ip -s link` | Node vừa reboot hoặc card vừa reload driver, bộ đếm về 0 rồi tăng lại |
| Corosync hiện `no local IP` trong khi `corosync-cfgtool -s` có `addr` | Đúng: `addr` lấy từ `corosync.conf`, nhưng `ip -br addr` cho thấy node không có interface mang IP đó |
