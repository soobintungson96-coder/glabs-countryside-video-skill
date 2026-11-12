# G-Labs Countryside Video — Claude Skill v3.7

Skill để **Claude lên kế hoạch, tạo và dựng** video đồng quê ASMR 16:9, không thoại, qua G-Labs Studio (adapter đã kiểm chứng trên máy này), có B-roll thiên nhiên/động vật, mỗi tập hoạt động khác nhau, xuất video + thumbnail + SEO tiếng Anh.

## Cài Skill
Thư mục `glabs-countryside-video` nằm trong `.claude/skills/` của workspace (`D:\Farm AI`). Key G-Labs đặt trong `<workspace>/.env.glabs` (không nằm trong skill, không chia sẻ).

## Cách sử dụng
- `/glabs-countryside-video dựng video với tiêu đề: <tiêu đề>` → Claude hỏi 5 thông số (từng mục nếu bạn muốn), xin duyệt cấu hình, lập kịch bản, xin duyệt, tạo ảnh tham chiếu, chạy thử 1 clip, rồi chạy từng phần.
- `/glabs-countryside-video gợi ý tiêu đề về ...` → danh sách ý tưởng tập.
- Gửi đường dẫn video mẫu trên máy → Claude phân tích cốt truyện, góc quay, màu (§16) và cập nhật phong cách.

## Quy tắc chính (v3.5–3.6)
- Mỗi nhân vật làm một việc riêng; hành động và âm thanh logic theo vị trí; máy quay tĩnh hoặc rất chậm.
- Ảnh tham chiếu nhân vật + bối cảnh + đạo cụ bắt buộc trước khi tạo video.
- Màu tươi, nịnh mắt nhưng chân thực, không "nhìn ra AI".
- Preset **Harvest & Cook** (§17), học từ 3 video mẫu: chuỗi 5–10 đoạn thu hoạch → nấu ăn, hook montage, ngữ pháp 6 bước, shot 4–6 s, B-roll động vật 35–45 %, ánh sáng high-key.

## File trong gói
- `SKILL.md` — hướng dẫn đầy đủ (§0–17).
- `references/`
  - `glabs-api.verified.md` — endpoint, header, model, thông số đo thật của meta_muse, từ dễ bị chặn.
  - `style-harvest-cook.md` + `style-samples/*.jpg` — phân tích video mẫu (dùng nội bộ để học phong cách, không sao chép).
  - `payload.schema.json`, `adapter-contract.md`, `continuity-uniqueness.md`.
- `examples/`
  - `bible.harvest_template.json` — bible mẫu cho preset Harvest & Cook.
  - `shotlist.harvest_template.txt` — khuôn shotlist (hook, đoạn 6 bước, kết).
  - `request.example.json`, `plan.example.json`, `SEO.example.txt`.
- `scripts/` (PowerShell, không cần Python; ffmpeg lấy từ G-Labs Studio)
  - `glabs.ps1` adapter · `build_storyboard.ps1` kịch bản + kiểm tra quy tắc · `run_shots.ps1` tạo clip song song (tới 20 luồng) · `make_sheet.ps1` ảnh QC · `assemble.ps1` dựng master bằng GPU (NVENC/QSV/AMF, tự lùi về CPU), màu `-Grade soft|bright`, loudness 2 lượt + limiter, nhạc `-MusicFile` · `export_delivery.ps1` thư mục giao hàng `<workspace>\YouTube\<Tiêu đề>\` (video, thumbnail, SEO, description, tags, youtube_metadata.json) · `analyze_reference.ps1` phân tích video mẫu · `validate_plan.py` (cần Python).

## Lưu ý
- Không gọi API trả phí trước khi bạn duyệt kế hoạch. Chi phí credit không được API báo — xem trong G-Labs.
- Nhạc nền phải có giấy phép (ví dụ YouTube Audio Library, "Attribution not required").
