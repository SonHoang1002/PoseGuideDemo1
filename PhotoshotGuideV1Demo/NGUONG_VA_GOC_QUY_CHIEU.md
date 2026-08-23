# PoseCoach — Ngưỡng chấp nhận & gốc quy chiếu (trả lời Câu hỏi 2)

Tài liệu này đi kèm `GuidanceEngine.swift` v2. Mục tiêu: trả lời chính xác
**đo cái gì, lấy gốc ở đâu, sai bao nhiêu thì im, sai bao nhiêu thì nhắc** —
và làm cho mọi con số đó nằm ở một chỗ duy nhất, sửa được trong 10 giây.

---

## 1. Vì sao v1 nhắc liên tục dù máy đã gần đúng

Bảy nguyên nhân, xếp theo mức đóng góp thực tế:

| # | Nguyên nhân trong v1 | Hậu quả | Cách sửa ở v2 |
|---|---|---|---|
| 1 | **Mục 3 & 4 so CHỈ SỐ BUCKET, dung sai = 0** | Template pitch −5° (bucket 2), máy đang −9° (bucket 1) → báo vi phạm dù chỉ lệch 4°. Đứng ngay ranh giới bucket thì tay rung 1° cũng lật bucket | So **số liên tục** với ngưỡng độ / đơn-vị-chiều-cao. Bucket chỉ dùng để **chọn chữ** ("ngang hông", "quá đầu") |
| 2 | **`pitchDeg` không được lọc** — 3 bộ One Euro chỉ lọc yaw/size/x | Mục 4 rung theo đúng nhịp tay | Lọc pitch riêng + lấy từ vector trọng lực (ổn định hơn `attitude.pitch`) |
| 3 | **Mục 3 phụ thuộc giả định "mẫu cao 1m70"** | Mẫu cao 1m55 → khoảng cách ước sai ~10% → độ cao máy sai ~10–15cm → **vi phạm vĩnh viễn**, người chụp làm gì cũng không tắt được cue | Đo theo **đơn vị chiều cao mẫu**: `rel = −f·tan(elev)/h_px`. Chiều cao thật bị triệt tiêu khỏi công thức |
| 4 | **`yaw = acos(r/rFront)` khuếch đại nhiễu gần chính diện** | Ở yaw ≈ 0, đạo hàm acos → ∞: r nhiễu 2% thành yaw nhiễu 12° | Lọc **r** trước khi acos (v1 lọc sau) + **vùng chết chính diện** `r/rFront ≥ 0.93 ⇒ yaw = 0` |
| 5 | **Không có debounce thời gian** | Một frame vượt ngưỡng là cue bật ngay, frame sau tắt | Vi phạm phải kéo dài **0.45s** mới hiện cue; đạt phải giữ **0.20s** mới tắt |
| 6 | **Không giới hạn thời gian hiển thị / không làm tròn số** | "Xoay 7 độ" → "Xoay 9 độ" → "Xoay 6 độ" trong 1 giây, user tưởng app loạn | Cue sống tối thiểu **1.2s**; số làm tròn bội **5°/5cm**; số chỉ cập nhật **1 lần/giây** |
| 7 | **Không có sàn hành động** | Báo "đưa máy sang phải" khi chỉ lệch 1.5% khung — người thật không làm nổi | Mỗi mục có `actionFloor`: dưới mức đó thì **im và tính là đạt** |

Thêm một lỗi tiềm ẩn cần kiểm ngay trên máy: v1 truyền `orientation: .up` cho
`VNImageRequestHandler`. Buffer của AVCapture là **landscape theo cảm biến**;
cầm dọc phải là `.right`. Nếu sai, trục X/Y của Vision bị hoán đổi so với khung
hình user nhìn thấy → mục 3 và mục 5 sai hệ thống mà không ai nhận ra.
v2 đưa nó thành `GuidanceConfig.visionOrientation` để test cả hai.

---

## 2. Bảng ngưỡng đầy đủ

Tất cả nằm trong `struct GuidanceConfig`. Ba con số cho mỗi mục:

- **accept** — trong ngưỡng này thì **ĐẠT**: im lặng, tính vào cổng chụp.
- **enter = accept × 1.5** — phải vượt mức này mới **bắt đầu** nhắc (vùng trễ).
- **unlock = accept × 3.0** — mục đã đạt chỉ bị mở khoá khi vượt mức này.
- **actionFloor** — lượng phải sửa nhỏ hơn mức này thì **im**, dù sai số vượt ngưỡng.

| Mục | Đại lượng đo | **Gốc quy chiếu** | Đơn vị | accept | enter | unlock | actionFloor |
|---|---|---|---|---|---|---|---|
| 1 Hướng mẫu | góc xoay thân quanh trục đứng, suy từ (bề ngang vai / chiều cao thân) | **0° = mẫu quay thẳng mặt vào máy**; ±180° = quay lưng. Điểm gốc hình học = **trung điểm hai vai** | độ | **30°** | 42° | 75° | 15° |
| 2 Xa/gần | `(tỉ_lệ_live / tỉ_lệ_template) − 1` | **Mốc đo phải trùng mốc của template** (đỉnh đầu→cổ chân, hoặc →gối, →hông, hoặc vai→hông). Xem §4 | tỉ lệ | **10%** | 15% | 30% | **0.35 m** |
| 3 Máy cao/thấp | `(cao_độ_máy − đỉnh_đầu) / chiều_cao_mẫu` | **Đỉnh đầu của mẫu = 0.0**. Âm = máy thấp hơn. Mắt ≈ −0.06 · hông ≈ −0.47 · gối ≈ −0.72 · đất = −1.0 | đơn-vị-chiều-cao-mẫu | **0.07 H** (≈ 12 cm với người 1m70) | 0.105 H | 0.21 H | 0.045 H (≈ 8 cm) |
| 4 Ngửa/chúc | góc ngẩng của **trục quang camera** | **Mặt phẳng ngang (⊥ vector trọng lực) = 0°**. Dương = ngửa lên trời | độ | **5°** | 7.5° | 15° | 4° |
| 5 Trái/phải | `X_tâm_thân_live − X_tâm_thân_template` | **Mép trái khung = 0.0, mép phải = 1.0**. Tâm thân = trung điểm của (giữa hai vai, giữa hai hông) | phần bề ngang khung | **5%** | 7.5% | 15% | 2% |
| 6a Trục thân | góc đoạn (giữa hông → giữa vai) | **trục dọc của khung hình** | độ | **10°** | 15° | 30° | 8° |
| 6b Hướng đầu | face yaw | 0° = mặt hướng thẳng vào máy | độ | **25°** | 35° | 75° | 15° |
| 6c/d Khớp tay & chân | góc tại khớp | **đỉnh góc = chính khớp đó** (vd. khuỷu: vai–khuỷu–cổ tay) | độ | **15°** | 22.5° | 45° | 12° |

### Ngưỡng thời gian

| Tham số | Giá trị | Ý nghĩa |
|---|---|---|
| `cueEnterHoldSeconds` | 0.45 s | vi phạm phải kéo dài ngần này mới hiện cue |
| `cueExitHoldSeconds` | 0.20 s | đạt phải giữ ngần này mới tắt cue |
| `cueMinDisplaySeconds` | 1.20 s | cue đã hiện phải ở lại ngần này (trừ khi mục ưu tiên cao hơn chen ngang) |
| `cueNumberRefreshSeconds` | 1.00 s | con số trong cue chỉ đổi mỗi giây một lần |
| `dwellSeconds` | 0.80 s | đủ 6 mục → giữ ổn định ngần này |
| `countdownSeconds` | 3.00 s | đếm ngược; **ghi bắt đầu ngay từ lúc bắt đầu đếm** |
| `countdownGraceSeconds` | 1.00 s | lệch ra giữa lúc đếm: chờ ngần này mới huỷ |
| `stallTimeoutSeconds` | 2.50 s | chống kẹt: mục đã khoá trôi vào vùng xám quá lâu → mở khoá, nhắc lại |
| `maxAngularSpeedDegPerSec` | 15 °/s | lắc mạnh hơn thì không cho vào dwell |
| `freezeCueAngularSpeedDegPerSec` | 45 °/s | lắc mạnh hơn thì đóng băng cue đang hiện |

### Preset

`GuidanceConfig.default` · `.strict` (chỉ để test độ chính xác) · `.relaxed`
(template dễ, hoặc người cầm máy hết kiên nhẫn). PRD đã chốt live chỉ cần đúng
80% — sai số còn lại được "rửa" ở khâu chọn khung offline + tự cắt ảnh, nên
`.relaxed` không làm hỏng chất lượng đầu ra như trực giác nghĩ.

---

## 3. Trả lời trực tiếp hai câu hỏi trong tài liệu

### "Góc xoay / độ nghiêng camera lệch bao nhiêu độ, lấy gốc là điểm nào?"

Ba góc khác nhau, ba gốc khác nhau, đừng trộn:

1. **Ngửa/chúc (mục 4)** — gốc là **mặt phẳng ngang**, xác định bằng vector
   trọng lực từ CoreMotion, **không phải** bằng cơ thể mẫu.
   `elevation = asin(gravity.z)` (trục quang camera sau = −z của device).
   Ngưỡng **±5°**, sàn hành động 4°. Cảm biến chính xác dưới 1° nên đây là
   mục duy nhất được siết chặt.
   *Không dùng `attitude.pitch` như v1*: nó phụ thuộc reference frame và bị
   gimbal lock khi cầm máy dựng đứng.

2. **Xoay trái/phải (mục 5)** — đây **không phải góc**, mà là **vị trí**:
   hiệu toạ độ X của tâm thân so với template, gốc là **mép trái khung**.
   Chỉ khi sinh câu chữ mới đổi sang độ:
   `deg = atan(offset × W_px / f)`. Lệch < 15% khung → "xoay máy"; ≥ 15% →
   "bước sang ngang" (xoay nhiều quá sẽ đổi phối cảnh, phá mục 2–4).

3. **Vẹo chân trời (roll)** — **không hướng dẫn**, theo PRD. Chỉ đọc để tự nắn
   ảnh nếu vẹo dưới 3°.

Còn **góc xoay của mẫu (mục 1)** thì gốc là **trung điểm hai vai**, 0° = mẫu
nhìn thẳng vào ống kính. Ngưỡng 30° rộng vì phép đo này (suy từ tỉ lệ vai/thân)
vốn có sai số ±8–10°; siết chặt hơn chỉ tạo cue giả.

### "Độ xa chênh bao nhiêu cm thì chấp nhận? Áp cho tất cả điểm hay một số điểm ưu tiên?"

**Không áp cho tất cả điểm — chỉ áp cho một mốc duy nhất mỗi frame**, và mốc đó
phải trùng mốc mà template đã dùng.

Lý do: khoảng cách tuyệt đối (cm) chỉ ước lượng được nếu biết chiều cao thật
của mẫu — mà ta không biết. Nên **ngưỡng gốc đặt theo tỉ lệ (10%)**, cm chỉ là
sản phẩm phụ để viết câu ("lùi 1 bước"). Với người 1m70 đứng cách 2.5m, 10%
tương đương **khoảng 25 cm**. Sàn hành động 0.35 m: chênh dưới 35 cm thì không
nhắc, vì người ta không "lùi nửa bước" theo lệnh được.

Thứ tự ưu tiên các mốc (`HeightAnchor`), lấy mốc tốt nhất còn đo được:

| Ưu tiên | Mốc | Phần chiều cao toàn thân | Khi nào dùng |
|---|---|---|---|
| 1 | đỉnh đầu → cổ chân | 0.96 | toàn thân trong khung |
| 2 | đỉnh đầu → gối | 0.715 | cắt ngang bắp chân |
| 3 | đỉnh đầu → hông | 0.47 | ảnh nửa người |
| 4 | vai → hông | 0.29 | ảnh cận, chỉ thấy thân |

Ba nhóm điểm mốc, độ tin cậy giảm dần:

- **Nhóm lõi** (vai ×2, hông ×2): dùng cho mục 1, 2, 3, 5. Ngưỡng confidence **0.50**.
- **Nhóm phụ** (mũi, mắt/tai, cổ chân, gối): dùng để lấy đỉnh đầu và mốc chiều
  cao. Ngưỡng **0.40**. Đỉnh đầu ưu tiên lấy từ **face bounding box**, sau đó
  mới suy từ nhân trắc (`đỉnh_đầu = cổ − 0.62 × chiều_cao_thân`).
- **Nhóm chi** (khuỷu, cổ tay, gối): chỉ dùng cho mục 6, thiếu thì **bỏ mục đó
  ra**, không trừ điểm — đúng nguyên tắc PRD.

Thêm: cần **3 frame liên tiếp** đo được nhóm lõi mới bắt đầu tin số đo
(`minValidFramesBeforeUse`).

---

## 4. Cổng chụp — điều kiện chính xác để tạm ngừng gợi ý

`readyToCapture == true` khi **đồng thời**:

1. Không còn vi phạm nào (danh sách rỗng), **và**
2. Cả 6 `CriterionGate` đều ở trạng thái `.passing` — tức từng mục đã ở trong
   `accept` liên tục ít nhất `cueExitHoldSeconds`, **và**
3. Tốc độ góc của máy ≤ 15 °/s (không đang đưa tay).

Rồi mới: giữ ổn định 0.8 s → bắt đầu đếm ngược 3 s → **ghi ngay từ lúc bắt đầu đếm**.

**Chống kẹt:** một mục đã khoá có thể trôi vào vùng xám (giữa `accept` và
`enter`) — khi đó nó không hiện cue nhưng cũng không mở cổng chụp. Nếu tình
trạng đó kéo dài quá `stallTimeoutSeconds` (2.5 s), mục đó bị mở khoá và nhắc
lại. Không có cơ chế này thì app sẽ đứng im vĩnh viễn mà user không hiểu vì sao.

---

## 5. Sổ tay chỉnh ngưỡng

| Hiện tượng khi test | Sửa gì |
|---|---|
| Cue vẫn nhảy qua lại giữa hai mục | ↑ `cueMinDisplaySeconds` (1.2 → 1.8) |
| Cue bật/tắt liên tục trong cùng một mục | ↑ `cueEnterHoldSeconds` (0.45 → 0.7) hoặc ↑ `accept` của mục đó |
| Đứng đúng rồi mà không chụp | Bật `UI.debugOverlay`, xem mục nào `x > 1.00`; nếu là mục 3 → kiểm lại `visionOrientation` và mốc đỉnh đầu |
| Con số trong cue nhảy | ↑ `quantizeDegrees` (5 → 10), ↑ `cueNumberRefreshSeconds` |
| App bắt chỉnh quá lâu mới cho chụp | Dùng `.relaxed`, hoặc ↑ `actionFloor` từng mục |
| Chụp lúc tay còn đang đưa | ↓ `maxAngularSpeedDegPerSec` (15 → 10), ↑ `dwellSeconds` |
| Mục 1 nhắc xoay khi mẫu đã đúng | ↑ `bodyYawFrontalDeadZone` (0.93 → 0.95) hoặc ↑ `bodyYaw.accept` |

`result.debug` in ra từng mục dạng `giá_trị / ngưỡng (x hệ_số)` — `x1.00` là
đúng ngay ngưỡng. Nên log 20 giây mỗi lần test rồi vẽ biểu đồ để chọn ngưỡng
bằng số liệu, không chọn bằng cảm giác.

---

## 6. Cần đo trên máy thật trước khi chốt số (iPhone 11)

1. **`visionOrientation`** — chạy cả `.up` và `.right`, xem mục 5 có phản ứng
   đúng chiều không. Đây là thứ phải kiểm đầu tiên.
2. **`focalPixels`** — bật `isCameraIntrinsicMatrixDeliveryEnabled` và so với
   giá trị suy từ `videoFieldOfView`. Sai 5% ở đây thì mục 3 sai ~5%.
3. **`rFront` mặc định 0.62** — quay 2 người khác vóc dáng (theo kế hoạch clip
   kiểm tra trong PRD, gồm cả người mặc áo rộng), lấy median thật.
4. **Nhiễu thực tế của từng đại lượng** — đặt máy trên tripod, người đứng yên
   20 giây, đo độ lệch chuẩn của yaw / sizeRatio / centerX / rel. **Quy tắc đặt
   `accept`: ≥ 3 lần độ lệch chuẩn.** Đây là cách duy nhất để biết ngưỡng nào
   là thật, ngưỡng nào chỉ đang đuổi theo nhiễu.
5. **Hệ số nhân trắc 0.62 và bảng `factorOfFullHeight`** — kiểm với ít nhất
   5 người, gồm cả người mặc áo rộng.
