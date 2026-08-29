# Local iOS Agent — foydalanish qo‘llanmasi

`Local iOS Agent` — macOS uchun native SwiftUI ilova. U Terminal oynasini ko‘rsatmasdan, tanlangan iOS loyiha papkasida lokal OpenCode agentini ishga tushiradi. Ilova OpenCode’ning JSON eventlarini tushunadi, haqiqiy sessiya ID’sini saqlaydi va keyingi xabarda shu agent kontekstini davom ettiradi.

## Yangi imkoniyatlar

- Chap panelda bir nechta lokal sessiyani yaratish, almashtirish va o‘chirish.
- Har sessiya uchun loyiha, model, chat tarixi va OpenCode sessiya ID’sini saqlash.
- Ilovani qayta ochganda oxirgi sessiyani avtomatik tiklash.
- OpenCode vosita holatlari, strukturali xatolar va texnik tafsilotlarni aniq ko‘rsatish.
- Markdown ko‘rinishidagi agent javoblari, nusxalash tugmasi va yaxshilangan composer.
- **Dependency Center** Ollama serveri va aniq model metadata’sini, OpenCode executable/versiya/model ro‘yxatini hamda XcodeBuildMCP `tools` va `doctor` holatini parallel tekshiradi.
- Loyiha preflight’i `.xcworkspace`, `.xcodeproj` yoki `Package.swift`, Git, `AGENTS.md` va XcodeBuildMCP skill faylini aniqlaydi.
- Bloklovchi muammo uchun aniq tuzatish yo‘riqnomasi va nusxalanadigan install/diagnostika komandasi ko‘rsatiladi.
- Swift 6 strict concurrency, chegaralangan JSON/process oqimi va xavfsiz to‘xtatish eskalatsiyasi.

## Talab qilinadigan lokal komponentlar

- macOS 14 yoki yangi versiya
- Xcode
- Ollama va `qwen3.5-ios:9b-64k`
- OpenCode
- XcodeBuildMCP CLI
- iOS loyiha ildizidagi `AGENTS.md`

Bu komponentlarni bir marta o‘rnatish uchun `INSTALL_LOCAL_IOS_AGENT.md` faylini Codex’ga bering. Tayyor iOS/Swift agent ko‘rsatmalari `AGENTS.md` faylida.

## Ilovani ishga tushirish

1. Paket ichidagi `dist` papkasini oching.
2. `Local iOS Agent.app` faylini `Applications` papkasiga ko‘chiring yoki bevosita oching.
3. macOS birinchi ochishda ogohlantirsa, Finder’da ilovani o‘ng tugma bilan bosing va **Open** ni tanlang. Ilova lokal yig‘ilgan va ad-hoc imzolangan, Apple notarizatsiyasidan o‘tmagan.
4. Yuqoridagi chaqmoq tugmasi bilan Ollama’ni oching.
5. Stetoskop tugmasi bilan **Dependency Center**’ni oching. Bloklovchi muammolarni kartadagi ko‘rsatma asosida tuzating va qayta tekshiring.
6. **Loyiha tanlash** tugmasini bosib `.xcodeproj` yoki `.xcworkspace` joylashgan loyiha ildiz papkasini tanlang.
7. Pastdagi maydonga vazifa yozib, `Command + Return` yoki yuborish tugmasini bosing.

Masalan:

```text
SwiftUI’da onboarding ekranini qo‘sh. Mavjud arxitekturani saqla, test yoz, XcodeBuildMCP orqali build va test qil, keyin natijani qisqa tushuntir.
```

## Tezkor amallar

- **Loyihani tahlil qilish** — fayllarni o‘zgartirmasdan arxitektura va targetlarni tekshiradi.
- **Build** — XcodeBuildMCP yordamida mos Simulator uchun build qiladi.
- **Test** — mavjud testlarni ishga tushiradi.
- **Simulator’da ochish** — build qilib Simulator’da ishga tushiradi va dastlabki loglarni tekshiradi.
- **Xcode’da ochish** — tanlangan loyihani Xcode’da ochadi.
- **To‘xtatish** — OpenCode jarayon daraxtini avval `SIGINT`, zarur bo‘lsa `SIGTERM` va oxirgi chora sifatida `SIGKILL` bilan xavfsiz to‘xtatadi.

## Sessiyalar qayerda saqlanadi?

Lokal tarix versiyalangan JSON arxiv sifatida quyidagi joyga atomik yoziladi:

```text
~/Library/Application Support/LocalIOSAgent/sessions-v1.json
```

Eng yangi 50 ta sessiya saqlanadi. Buzilgan yoki kelajak versiyadagi arxiv yuklash paytida ustidan yozilmaydi. Lokal tarixni UI’dan o‘chirish OpenCode’ning o‘z bazasidagi sessiyani o‘chirmaydi.

## Model sozlamasi

Standart model:

```text
ollama/qwen3.5-ios:9b-64k
```

Uni **Model va sozlamalar** oynasida almashtirish mumkin. Model nomi OpenCode’dagi `provider/model` formatida bo‘lishi kerak.

## Muhim eslatmalar

- Inference localhost’dagi Ollama orqali bajariladi; ilova bulut API kalitini talab qilmaydi.
- Agent loyiha fayllarini tahrir qilishi va lokal buyruqlarni bajarishi mumkin. Loyiha Git nazoratida bo‘lsin va muhim o‘zgarishlardan oldin commit yarating.
- M1 Pro va 16 GB RAM’da 9B model amaliy iOS vazifalari uchun yetarli, lekin katta loyiha yoki juda uzun sessiyada sekinlashishi mumkin. Vazifalarni kichik bosqichlarga ajratish yaxshiroq natija beradi.
- Ilova o‘rnatish vositasi emas. Ollama, OpenCode va XcodeBuildMCP avval bir marta o‘rnatilgan bo‘lishi kerak.

## Manba kodi va qayta build

Manba kodi paketning `Sources` papkasida. Xcode 26 / Swift 6 bilan tekshirilgan. Joriy paketda 28 ta unit/integration test mavjud.

```text
swift test
swift test --sanitize=thread
./scripts/package_app.sh
```

Release `.app` bundle `dist/Local iOS Agent.app` ichida hosil bo‘ladi.
