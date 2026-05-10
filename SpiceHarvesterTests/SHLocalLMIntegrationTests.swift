import Foundation
import Testing
@testable import SpiceHarvester

/// Integrační testy proti běžícímu lokálnímu LLM serveru na `127.0.0.1:1234`
/// (LM Studio default). Testy se **automaticky přeskakují** (s tištěnou poznámkou
/// "skipped"), pokud server běží není dostupný — to umožňuje, aby běžný `xcodebuild
/// test` neselhal v CI bez LM Studia, ale stejné testy se spouští v plné formě
/// při lokálním vývoji s běžícím modelem.
///
/// Pokud chcete tyto testy běžně přeskakovat (i když je LM Studio dostupné),
/// nastavte env proměnnou `SH_SKIP_LM_INTEGRATION=1`.
struct SHLocalLMIntegrationTests {

    private static let serverBaseURL = "http://127.0.0.1:1234/v1"
    /// Generous because thinking models (Qwen3, DeepSeek-R1) can spend 60-120 s
    /// on chain-of-thought even at temperature 0. Test fails outright above this
    /// threshold so we catch genuinely-stuck setups, not slow-but-working ones.
    private static let inferenceTimeoutSeconds: TimeInterval = 600
    /// Reachability probe is intentionally short — we want to skip fast when
    /// nothing is listening, not block the whole test suite.
    private static let probeTimeoutSeconds: TimeInterval = 5

    // MARK: – Helpers

    private static func skipMarker() -> String? {
        if let value = ProcessInfo.processInfo.environment["SH_SKIP_LM_INTEGRATION"],
           !value.isEmpty, value != "0" {
            return "SH_SKIP_LM_INTEGRATION=\(value) — test přeskočen na žádost prostředí"
        }
        return nil
    }

    private static func makeServer() -> SHServerConfig {
        SHServerConfig(name: "Local LM (test)", baseURL: serverBaseURL, apiKey: "")
    }

    private static func makeProbeClient() -> SHOpenAICompatibleClient {
        // Single-attempt probe so a down server fails the probe in ~5 s instead
        // of triggering the default 3-attempt retry chain (15-30 s).
        SHOpenAICompatibleClient(maxAttempts: 1, requestTimeoutSeconds: Int(probeTimeoutSeconds))
    }

    /// Vrací seznam dostupných modelů, nebo `nil` pokud server nereaguje. Tisk
    /// hláška vysvětluje, proč test zachová "passed" stav i když nedoběhl —
    /// integrační testy mají v tomto projektu být **podmíněné**, ne fatální.
    private static func availableModelsOrNil() async -> [String]? {
        if let reason = skipMarker() {
            print("⏭️  \(reason)")
            return nil
        }
        let server = makeServer()
        let client = makeProbeClient()
        do {
            let models = try await client.fetchModels(server)
            return models
        } catch {
            print("⏭️  LM Studio na \(serverBaseURL) není dostupné: \(error.localizedDescription) — integrační test přeskočen.")
            return nil
        }
    }

    // MARK: – 1. Reachability

    /// Smoke test: server odpoví na `/v1/models` a vrátí alespoň jeden model.
    /// Když server není dostupný, test se přeskočí (passes silently) — viz
    /// dokumentace u `availableModelsOrNil`.
    @Test func localLMServerReachableAndHasModels() async throws {
        guard let models = await Self.availableModelsOrNil() else { return }

        #expect(!models.isEmpty,
                "Server na \(Self.serverBaseURL) odpověděl, ale nemá načtený žádný model. V LM Studiu nahraj model a opakuj test.")
        print("✅ LM Studio dostupné, modely: \(models.prefix(5).joined(separator: ", "))\(models.count > 5 ? " …" : "")")
    }

    // MARK: – 2. End-to-end extrakce z 50 kB lab. protokolu

    /// Vygeneruje syntetický český laboratorní protokol cca 50 kB, pošle ho
    /// reálnému LLM s extrakčním promptem a ověří:
    ///   1. odpověď je validní JSON,
    ///   2. obsahuje očekávané pole pacienta (`Novák Jan`),
    ///   3. extrahováno bylo alespoň 5 laboratorních hodnot (model nesmí
    ///      vrátit prázdný/halucinovaný výstup),
    ///   4. inference proběhla pod limitem `inferenceTimeoutSeconds`.
    ///
    /// Tisk metrik (čas, throughput, počet hodnot) jde do konzole a slouží jako
    /// rychlý benchmark výkonu lokálního setupu — neassertujeme konkrétní
    /// rychlost, protože ta závisí na hardwaru.
    @Test func extractsLabValuesFromSyntheticReport() async throws {
        guard let models = await Self.availableModelsOrNil() else { return }
        guard let model = models.first else {
            print("⏭️  V LM Studiu není načtený žádný model — test přeskočen.")
            return
        }

        // 1) Příprava: vygeneruj a ulož 50 kB protokol, abychom měli ověřený
        // round-trip přes filesystem (ne jen in-memory string).
        let document = SHLabReportFixture.synthesize(targetBytes: 50_000)
        let documentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spice-lab-test-\(UUID().uuidString).txt")
        try document.write(to: documentURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: documentURL) }

        let onDiskBytes = (try? Data(contentsOf: documentURL).count) ?? 0
        #expect(onDiskBytes >= 45_000 && onDiskBytes <= 60_000,
                "Vygenerovaný protokol má \(onDiskBytes) B — mimo rozsah 45–60 kB.")

        let documentText = try String(contentsOf: documentURL, encoding: .utf8)

        // 2) Extrakční prompt — analogický s reálným použitím aplikace.
        // Schéma je úmyslně minimální (4 pole), aby test nebyl citlivý na
        // přesnou podobu kanonického `SHExtractionResult` schématu.
        let userPrompt = """
        Extrahuj z následujícího laboratorního protokolu data jako JSON ve formátu:
        {
          "patient_name": "celé jméno pacienta",
          "patient_id": "rodné číslo pacienta nebo prázdný řetězec",
          "lab_values": ["název hodnota jednotka", "..."],
          "summary": "stručné jednovětové shrnutí závěru"
        }

        - "lab_values" musí obsahovat všechny laboratorní hodnoty z dokumentu, jednu na řádek pole.
        - Vracej VÝHRADNĚ validní JSON podle schématu, žádný markdown ani komentář.

        DOKUMENT:
        \(documentText)
        """

        // 3) Inference s plným timeoutem. Použijeme minimální maxAttempts, aby
        // test nezdvojnásobil délku při flaky síti — chceme reálnou jednu
        // round-trip metriku.
        let client = SHOpenAICompatibleClient(maxAttempts: 1, requestTimeoutSeconds: Int(Self.inferenceTimeoutSeconds))
        let server = Self.makeServer()
        let systemPrompt = "Jsi extrakční engine. Odpovídej výhradně validním JSON podle schématu ze zadání. Nevracej markdown ani vysvětlení."

        let start = Date()
        let response: String
        do {
            response = try await client.chatJSON(
                server: server,
                model: model,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            )
        } catch {
            Issue.record("LM inference selhala: \(error.localizedDescription)")
            return
        }
        let elapsed = Date().timeIntervalSince(start)

        // 4) Parse a kvalita. Některé modely zabalí JSON do ```json bloku i přes
        // explicit instrukci — tolerujeme to stripováním fence markerů.
        let cleaned = SHLabReportFixture.stripCodeFence(response)

        guard let payload = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            Issue.record("Odpověď není validní JSON. Prvních 300 B: \(cleaned.prefix(300))")
            return
        }

        let patientName = (json["patient_name"] as? String) ?? ""
        let patientID = (json["patient_id"] as? String) ?? ""
        let labValues = (json["lab_values"] as? [String]) ?? []
        let summary = (json["summary"] as? String) ?? ""

        // Jméno: tolerujeme variantu s háčkem i bez (modely občas přepisují diakritiku).
        let nameMatchesNovak = patientName.localizedCaseInsensitiveContains("novák")
            || patientName.localizedCaseInsensitiveContains("novak")
        #expect(nameMatchesNovak,
                "patient_name neobsahuje očekávané jméno 'Novák'. Skutečnost: \(patientName.isEmpty ? "<prázdné>" : patientName)")

        #expect(!patientID.isEmpty,
                "patient_id je prázdné — model neexrahoval rodné číslo z hlavičky protokolu.")

        // Z 50 kB protokolu (~80–100 lab. hodnot) musí model vrátit aspoň 5,
        // jinak skoro jistě skipuje obsah nebo vrátil halucinaci.
        #expect(labValues.count >= 5,
                "Z 50 kB lab. protokolu byly extrahovány jen \(labValues.count) hodnoty — model pravděpodobně přeskakuje obsah nebo halucinuje.")

        #expect(elapsed < Self.inferenceTimeoutSeconds,
                "Inference trvala \(String(format: "%.1f", elapsed)) s, což překračuje limit \(Self.inferenceTimeoutSeconds) s.")

        // 5) Metriky. Záležejí na HW, takže neassertujeme, ale uložíme je do
        // souboru v `/tmp/spice-lab-benchmark-*.txt` (a vypíšeme i `print`).
        // Soubor je spolehlivý kanál — `print` ze Swift Testing není přes
        // `xcodebuild test` na stdout vždy viditelný (na rozdíl od XCTest).
        let throughputBps = Double(onDiskBytes) / max(elapsed, 0.001)
        let report = """
        📊 Lab extraction benchmark
        ----------------------------
        model:       \(model)
        input:       \(onDiskBytes) B (\(String(format: "%.1f", Double(onDiskBytes) / 1024.0)) kB)
        inference:   \(String(format: "%.2f", elapsed)) s
        throughput:  \(String(format: "%.0f", throughputBps)) B/s vstup

        extracted:
          • patient_name: \(patientName)
          • patient_id:   \(patientID)
          • lab_values:   \(labValues.count) položek
          • summary:      \(summary.prefix(200))\(summary.count > 200 ? "…" : "")

        first 5 lab_values:
        \(labValues.prefix(5).map { "  - \($0)" }.joined(separator: "\n"))
        """
        print(report)

        let benchmarkURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("spice-lab-benchmark-\(Int(Date().timeIntervalSince1970)).txt")
        try? report.write(to: benchmarkURL, atomically: true, encoding: .utf8)
        print("📁 Benchmark uložen: \(benchmarkURL.path)")
    }
}

// MARK: – Synthetic lab-report fixture

/// Generátor pseudo-realistického českého laboratorního protokolu pro
/// integrační testy. **Není to lékařsky validovaný obsah** — je to syntéza
/// věrohodně vypadajících čísel, jednotek a textu, jejíž **jediná funkce** je
/// sloužit jako vstup s reálnou strukturou (ne lorem ipsum) pro extrakční
/// testy.
enum SHLabReportFixture {

    /// Vrátí dokument naplněný cca `targetBytes` byty (UTF-8). Konkrétně
    /// generuje hlavičku, hematologii, biochemii, koagulaci, moč chemicky a
    /// sediment + opakované série pro různá data odběru, dokud nedosáhne cílové
    /// velikosti. Velikost se chová ±10 % kolem cíle.
    static func synthesize(targetBytes: Int) -> String {
        var output = header()
        output += anamnesis()
        output += "\n\n"

        // Postupně přidáváme měření z různých dnů, dokud netrefíme target.
        var seriesIndex = 0
        let baseDate = Date(timeIntervalSince1970: 1_715_000_000) // ~květen 2024
        let day: TimeInterval = 86_400

        while output.utf8.count < targetBytes {
            seriesIndex += 1
            let measurementDate = baseDate.addingTimeInterval(day * Double(seriesIndex - 1))
            output += measurementBlock(seriesIndex: seriesIndex, date: measurementDate)
        }

        output += conclusion()
        return output
    }

    /// Strip Markdown code fences (```json … ```), které některé modely vrátí
    /// i přes explicitní instrukci. Bezpečné no-op když fence chybí.
    static func stripCodeFence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fences = ["```json", "```JSON", "```"]
        for fence in fences {
            if t.hasPrefix(fence) {
                t = String(t.dropFirst(fence.count))
            }
            if t.hasSuffix(fence) {
                t = String(t.dropLast(fence.count))
            }
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: – Sections

    private static func header() -> String {
        """
        FAKULTNÍ NEMOCNICE PRAHA
        Klinika laboratorní medicíny
        Adresa: U Nemocnice 499/2, 128 08 Praha 2
        IČO: 00064173

        ===========================================================
        LABORATORNÍ NÁLEZ – SOUHRNNÝ PROTOKOL
        ===========================================================

        Pacient:        Novák Jan
        Rodné číslo:    850101/1234
        Datum narození: 01.01.1985
        Pohlaví:        muž
        Pojišťovna:     111 (Všeobecná zdravotní pojišťovna)
        Oddělení:       Interní klinika, lůžková část
        Indikující lékař: MUDr. Petra Svobodová
        Datum přijetí:  03.05.2024
        Datum vyšetření: 04.05.2024 — 12.05.2024
        Materiál:       krev žilní, moč, koagulace
        Identifikátor protokolu: LAB-2024-0509-118

        ===========================================================


        """
    }

    private static func anamnesis() -> String {
        """
        ANAMNÉZA
        --------
        Osobní: arteriální hypertenze diagnostikována 2018, dyslipidémie 2020,
        chronická ischemická choroba srdeční (NSTEMI 2022, primární PCI RIA),
        diabetes mellitus 2. typu od 2021 (HbA1c 64 mmol/mol v 03/2024),
        chronická renální insuficience CKD G3a (eGFR 51 ml/min/1.73m²),
        steatóza jater. Bývalý kuřák (15 PY, abstinence od 2022).

        Rodinná: otec exitus 2015 v 68 letech (IM); matka žije, 80 let, AH a DM2.
        Sourozenec — sestra zdravá. Děti dvě, zdravé.

        Léková: Prestarium Neo Combi 5/1.25 mg 1-0-0, Concor 5 mg 1-0-1,
        Atoris 40 mg 0-0-1, Anopyrin 100 mg 0-1-0, Metformin 1000 mg 1-0-1,
        Empagliflozin 10 mg 1-0-0, Pantoprazol 20 mg 1-0-0 (v.p.).

        Sociální: SVJ, ženatý, dvě děti. Pracuje jako projektant; práce
        sedavá, fyzická aktivita lehká (chůze 30–45 min/den).

        Nynější onemocnění: pacient přijat pro 2 dny trvající stenokardii
        s vyzařováním do levé horní končetiny při zátěži, dnes ráno
        klidová bolest, intenzita VAS 6/10, trvání 30 min, ústup po SL NTG.
        EKG při příjmu: SR 78/min, deprese ST 0.5–1 mm V4–V6.
        Troponin I při příjmu 124 ng/L (norma <34), kontrola za 3 h
        287 ng/L. Indikována koronarografie.


        """
    }

    /// Generuje blok měření z jednoho dne. ~3 kB textu na blok.
    private static func measurementBlock(seriesIndex: Int, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy"
        formatter.locale = Locale(identifier: "cs_CZ")
        let dateString = formatter.string(from: date)

        // Rozumný drift hodnot napříč dny — pacient po STEMI postupně stabilizován.
        let drift = Double(seriesIndex - 1) * 0.03

        var section = """

        ===========================================================
        Série \(seriesIndex) — odběr \(dateString)
        ===========================================================

        HEMATOLOGIE
        -----------
        \(line("Hemoglobin",                  142 - drift * 5,    g_l, "135–175"))
        \(line("Hematokrit",                  0.42 - drift * 0.01, "—",  "0.40–0.50"))
        \(line("Erytrocyty",                  4.9 - drift * 0.05, "10^12/L", "4.3–5.7"))
        \(line("MCV",                         87.0,                "fL",     "82–98"))
        \(line("MCH",                         29.0,                "pg",     "28–34"))
        \(line("MCHC",                        333.0,               "g/L",    "320–360"))
        \(line("Trombocyty",                  235 + drift * 4,     "10^9/L", "150–400"))
        \(line("Leukocyty",                   8.4 - drift * 0.1,   "10^9/L", "4.0–10.0"))
        \(line("Neutrofily segmentované",     65.5,                "%",      "45–70"))
        \(line("Lymfocyty",                   24.5,                "%",      "20–45"))
        \(line("Monocyty",                    7.5,                 "%",      "2–10"))
        \(line("Eozinofily",                  2.0,                 "%",      "0–7"))
        \(line("Bazofily",                    0.5,                 "%",      "0–2"))
        \(line("Retikulocyty",                12.0,                "‰",      "5–25"))

        BIOCHEMIE
        ---------
        \(line("Glukóza nalačno",             6.8 - drift * 0.1,   "mmol/L", "3.9–5.6"))
        \(line("HbA1c",                       58 - drift,          "mmol/mol", "<48"))
        \(line("Urea",                        7.2 - drift * 0.1,   "mmol/L", "2.8–8.1"))
        \(line("Kreatinin",                   118 - drift * 2,     "μmol/L", "62–106"))
        \(line("Kyselina močová",             362 - drift * 5,     "μmol/L", "200–420"))
        \(line("eGFR (CKD-EPI)",              51 + drift,          "ml/min/1.73m²", ">60"))
        \(line("Sodík",                       139,                 "mmol/L", "136–145"))
        \(line("Draslík",                     4.5,                 "mmol/L", "3.5–5.1"))
        \(line("Chloridy",                    102,                 "mmol/L", "98–107"))
        \(line("Vápník celkový",              2.32,                "mmol/L", "2.15–2.55"))
        \(line("Vápník ionizovaný",           1.18,                "mmol/L", "1.15–1.32"))
        \(line("Hořčík",                      0.85,                "mmol/L", "0.66–1.07"))
        \(line("Fosfor anorganický",          1.05,                "mmol/L", "0.78–1.65"))

        JATERNÍ TESTY
        -------------
        \(line("Bilirubin celkový",           14.0,                "μmol/L", "3.4–17.0"))
        \(line("Bilirubin přímý",             3.5,                 "μmol/L", "0.0–5.0"))
        \(line("AST",                         32,                  "U/L",    "<40"))
        \(line("ALT",                         28,                  "U/L",    "<41"))
        \(line("GGT",                         48,                  "U/L",    "<55"))
        \(line("ALP",                         88,                  "U/L",    "40–129"))
        \(line("LDH",                         210,                 "U/L",    "<248"))
        \(line("Cholinesteráza",              7800,                "U/L",    "5320–12920"))
        \(line("Albumin",                     38.5,                "g/L",    "35–52"))
        \(line("Proteinurie / Protein C",     74.0,                "g/L",    "66–83"))

        KARDIOMARKERY
        -------------
        \(line("Troponin I — vstup",          287 - drift * 30,    "ng/L",   "<34"))
        \(line("Troponin I — kontrola",       412 - drift * 30,    "ng/L",   "<34"))
        \(line("CK celkový",                  328,                 "U/L",    "<190"))
        \(line("CK-MB",                       28,                  "U/L",    "<25"))
        \(line("Myoglobin",                   140,                 "μg/L",   "<72"))
        \(line("NT-proBNP",                   980 - drift * 80,    "ng/L",   "<125"))
        \(line("D-dimery",                    0.51,                "mg/L",   "<0.5"))
        \(line("hs-CRP",                      4.2 - drift * 0.05,  "mg/L",   "<5"))

        LIPIDOGRAM
        ----------
        \(line("Cholesterol celkový",         5.2 - drift * 0.05,  "mmol/L", "<5.0"))
        \(line("HDL cholesterol",             1.05,                "mmol/L", ">1.0"))
        \(line("LDL cholesterol",             3.0 - drift * 0.05,  "mmol/L", "<1.4 (po IM)"))
        \(line("Triglyceridy",                1.85,                "mmol/L", "<1.7"))
        \(line("Non-HDL cholesterol",         4.15,                "mmol/L", "<2.2"))

        KOAGULACE
        ---------
        \(line("INR",                         1.05,                "—",      "0.8–1.2"))
        \(line("Quickův test (PT)",           12.5,                "s",      "10–13"))
        \(line("APTT",                        32.0,                "s",      "26–38"))
        \(line("Fibrinogen",                  3.4,                 "g/L",    "1.8–3.5"))
        \(line("Antithrombin III",            104,                 "%",      "80–120"))

        TYREOIDÁLNÍ HORMONY
        --------------------
        \(line("TSH",                         2.4,                 "mIU/L",  "0.27–4.20"))
        \(line("fT4",                         15.5,                "pmol/L", "12.0–22.0"))
        \(line("fT3",                         4.8,                 "pmol/L", "3.1–6.8"))

        ZÁNĚTLIVÉ MARKERY A ŽELEZO
        ---------------------------
        \(line("CRP",                         28 - drift * 1.5,    "mg/L",   "<5"))
        \(line("Prokalcitonin",               0.18,                "μg/L",   "<0.5"))
        \(line("Železo",                      14.5,                "μmol/L", "10.7–28.6"))
        \(line("Ferritin",                    188,                 "μg/L",   "30–400"))
        \(line("Transferrin",                 2.5,                 "g/L",    "2.0–3.6"))
        \(line("Saturace transferrinu",       28,                  "%",      "20–55"))

        MOČ — CHEMICKY
        --------------
        \(line("pH moči",                     5.5,                 "—",      "5.0–8.0"))
        \(line("Specifická hmotnost",         1.020,               "—",      "1.005–1.030"))
        \(line("Bílkovina v moči",            0.10,                "g/L",    "<0.15"))
        \(line("Glukóza v moči",              0.0,                 "mmol/L", "0"))
        \(line("Ketolátky",                   0.0,                 "mmol/L", "0"))
        \(line("Krev v moči",                 0.0,                 "—",      "neg"))
        \(line("Nitrity",                     0.0,                 "—",      "neg"))
        \(line("Leukocyty v moči",            0.0,                 "—",      "neg"))


        """

        return section
    }

    private static let g_l = "g/L"

    private static func line(_ name: String, _ value: Double, _ unit: String, _ range: String) -> String {
        // Sloupcový layout pro vizuální čitelnost — extrakční model takový text
        // dobře parsuje, padding udržuje stabilní formát.
        let formattedValue: String = {
            if abs(value - value.rounded()) < 0.0001 && abs(value) < 1_000_000 {
                return String(format: "%.0f", value)
            }
            return String(format: "%.2f", value)
        }()
        let nameCol = name.padding(toLength: 35, withPad: " ", startingAt: 0)
        let valueCol = formattedValue.padding(toLength: 10, withPad: " ", startingAt: 0)
        let unitCol = unit.padding(toLength: 12, withPad: " ", startingAt: 0)
        return "\(nameCol)\(valueCol)\(unitCol)norma: \(range)"
    }

    private static func conclusion() -> String {
        """

        ===========================================================
        ZÁVĚR LÉKAŘE
        ===========================================================

        Pacient s akutním koronárním syndromem typu NSTEMI,
        provedena urgentní koronarografie s nálezem 80% stenózy RIA
        a 60% stenózy ACx. Implantován 1× DES do RIA, terapeutický
        úspěch, plný flow TIMI 3. V průběhu hospitalizace stabilní
        oběh, bolesti odezněly, troponin postupně klesá.

        Doporučení:
          • DAPT (ASA + tikagrelor) 12 měsíců, dále ASA monoterapie
          • atorvastatin 80 mg 0-0-1, cíl LDL <1.4 mmol/L
          • bisoprolol 5 mg 1-0-0, dle TK možno titrovat
          • perindopril/indapamid 5/1.25 mg 1-0-0
          • empagliflozin 10 mg 1-0-0 (renoprotektivně, kardioprotektivně)
          • metformin 1000 mg 1-0-1, kontrola HbA1c za 3 měsíce
          • dietní opatření, rehabilitace dle protokolu kardiocentra

        Datum propuštění: 12.05.2024
        Lékař: MUDr. Petra Svobodová, Ph.D.
        ===========================================================
        """
    }
}
