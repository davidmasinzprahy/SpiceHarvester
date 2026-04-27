import SwiftUI

/// First-run help sheet shown via the "?" toolbar button. Pure documentation –
/// no state of its own beyond the dismiss callback supplied by the caller.
struct HelpSheet: View {
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)
                Text("Jak Spice Harvester funguje")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Zavřít")
                .accessibilityLabel("Zavřít nápovědu")
            }
            .padding(20)
            .background(.thinMaterial)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    section(icon: "sparkles", title: "Co aplikace dělá") {
                        paragraph("**Spice Harvester** je nástroj pro hromadné vytěžování dat z dokumentů pomocí lokálního AI modelu. Aplikace projde složku s PDF soubory, extrahuje z nich text (v případě potřeby i pomocí OCR), pošle texty lokálnímu AI modelu s vašimi pokyny a výsledky uloží jako strukturovaná data (JSON / CSV).")
                        paragraph("Všechno běží **lokálně ve vašem počítači** – žádná data neopouští zařízení. Hodí se proto i pro citlivé dokumenty (smlouvy, lékařské zprávy, faktury, výkazy, propouštěcí zprávy, audity…).")
                    }

                    section(icon: "wrench.and.screwdriver.fill", title: "Co si předem připravit") {
                        step(1, "Nainstalujte **LM Studio** nebo **MLX server** s OpenAI-compatible API. Pro MLX typicky běží server na `http://localhost:8000/v1`.")
                        step(2, "Stáhněte nebo načtěte **AI model** – doporučeno třeba **Qwen3**, **Llama 3** nebo **Mistral**. Větší model = přesnější výsledky, ale pomalejší.")
                        step(3, "Spusťte **lokální server**. LM Studio obvykle používá `http://localhost:1234/v1`, MLX backendy často `http://localhost:8000/v1`.")
                        step(4, "Připravte si složku s **PDF dokumenty**, které chcete zpracovat.")
                    }

                    section(icon: "list.number", title: "Postup v aplikaci") {
                        step(1, "**Složky** – nastavte Vstup (kde jsou PDF), Výstup (kam uložit výsledky), Cache (dočasná data) a Prompty (složka s uloženými .md prompty). Cesty lze zkopírovat **drag-and-drop** přímo do políčka.")
                        step(2, "**Server** – klikněte na „+\" pro LM Studio nebo **MLX** pro MLX preset. Vložte Base URL lokálního serveru a klikněte **„Ověřit server\"**. Po úspěchu tlačítko zezelená a načtou se dostupné modely.")
                        step(3, "**Model** – vyberte stažený Inference model. Embedding model volte jen pokud chcete používat režim SEARCH.")
                        step(4, "**Režim** – zvolte FAST, SEARCH nebo CONSOLIDATE (popis níže).")
                        step(5, "**Prompt** – napište pokyn pro AI přímo do pole (co z dokumentů vytěžit a v jakém formátu), nebo ho načtěte ze složky tlačítkem **„Načíst ze složky\"**.")
                        step(6, "Klikněte na **„Spustit\"** v horní liště okna (nebo Cmd+R). Průběh sledujte v kartě Průběh a v detailním logu vespod.")
                        step(7, "Po dokončení klikněte na **„Výstup\"** – aplikace otevře složku s výsledky přímo ve Finderu.")
                    }

                    section(icon: "slider.horizontal.3", title: "Režimy extrakce") {
                        mode(symbol: "bolt.fill", name: "FAST",
                             desc: "Nejrychlejší. Na každý dokument jeden požadavek na AI. Bez RAG a bez embeddingů. Vhodné pro kratší dokumenty a rychlé dávky.")
                        mode(symbol: "magnifyingglass", name: "SEARCH",
                             desc: "RAG režim. Každý dokument se rozdělí na části, vyhledají se relevantní pasáže (přes embedding model) a jen ty se pošlou AI. Vhodné pro dlouhé dokumenty.")
                        mode(symbol: "square.stack.3d.up.fill", name: "CONSOLIDATE",
                             desc: "Všechny dokumenty se sloučí do jednoho požadavku. Model vrátí jednu agregovanou odpověď přes celou dávku (např. jedno JSON pole). Vyžaduje model s velkým kontextem.")
                    }

                    section(icon: "lightbulb.fill", title: "Tipy a užitečné detaily") {
                        bullet("Pokročilá nastavení (souběžnost, throttle, kontext modelu, timeout, cache, OCR backend) najdete v **Předvolbách** (Cmd+,).")
                        bullet("Při prvním běhu se změří výkon – každý další běh pak v kartě **Průběh** zobrazí odhad doby (ETA).")
                        bullet("Pokud prompt říká něco jiného, než aktuální nastavení dovoluje, objeví se pod ním **barevný banner** s návrhem na opravu. Jedním klikem (a potvrzením) se změní nastavení.")
                        bullet("Dlouhý běh můžete kdykoli **přerušit** červeným tlačítkem v toolbaru (Cmd+. funguje také). Přerušením se neztratí již zpracované dokumenty – pokračování využije cache.")
                        bullet("Výsledky jsou deterministické díky cache LLM odpovědí. Pokud chcete cache vynechat, přepněte si to v Předvolbách → Cache.")
                        bullet("Pokud model zamrzne nebo server neodpovídá, po nastavené době **Timeoutu** (Předvolby → Výkon) se požadavek automaticky opakuje.")
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Spacer()
                Button("Zavřít") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.thinMaterial)
        }
        .frame(minWidth: 640, idealWidth: 720, maxWidth: 900,
               minHeight: 600, idealHeight: 780, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 22)
                Text(title)
                    .font(.title3.weight(.semibold))
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.leading, 4)
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(.init(text))
            .font(.body)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(.primary)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number).")
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.blue)
                .frame(width: 22, alignment: .trailing)
            Text(.init(text))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 5))
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 7)
            Text(.init(text))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func mode(symbol: String, name: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 22, alignment: .center)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.body.weight(.semibold))
                Text(desc)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
