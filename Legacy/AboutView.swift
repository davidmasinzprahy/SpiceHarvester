import SwiftUI

struct AboutView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private var palette: GlassPalette {
        GlassPalette.forScheme(colorScheme)
    }

    var body: some View {
        ZStack {
            GlassBackground(palette: palette)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    quickStartSection
                    preflightChecksSection
                    localLMStudioSection
                    remoteLMStudioSection
                    heartbeatSection
                    resumeSection
                    workflowSection
                    processingBehaviorSection
                    troubleshootingSection
                    formatsSection
                    closeHelpButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 760, height: 760)
    }

    private var header: some View {
        section(
            title: "Nápověda",
            subtitle: "Rychlý návod k použití Spice Harvesteru s LM Studiem na stejném nebo vzdáleném počítači.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Spice Harvester dávkově zpracuje vybrané soubory, předá jejich obsah modelu přes OpenAI-kompatibilní API adresu a uloží jednotlivé i souhrnné výstupy do zadané výstupní složky.")
                    .foregroundStyle(palette.textPrimary)

                Text("Nejjednodušší použití je: vybrat vstup a výstup, počkat na diagnostiku, upravit prompt a pak kliknout na Spustit prompt.")
                    .foregroundStyle(palette.textPrimary)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .lineSpacing(4)
        }
    }

    private var quickStartSection: some View {
        section(
            title: "Rychlý start",
            subtitle: "Když chceš aplikaci rozběhnout během minuty.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 8) {
                helpStep("1. Spusť LM Studio a načti model, který chceš použít.")
                helpStep("2. V LM Studiu zapni lokální server kompatibilní s OpenAI API.")
                helpStep("3. Ve Spice Harvesteru klikni na pole Vstup a vyber vstupní složku s dokumenty.")
                helpStep("4. Klikni na pole Výstup a vyber složku pro uložení výsledků.")
                helpStep("5. Ověř, že se v obou polích zobrazuje plná cesta ke složce.")
                helpStep("6. Napiš prompt ručně nebo načti `.txt/.md` soubor tlačítkem `Načti prompt ze souboru`.")
                helpStep("7. Zkontroluj text přímo v prompt okně. Rozhodující je vždy to, co je v okně vidět.")
                helpStep("8. Spusť `Spustit prompt`.")
            }
        }
    }

    private var localLMStudioSection: some View {
        section(
            title: "LM Studio na stejném počítači",
            subtitle: "Výchozí a nejjednodušší režim.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Situace: LM Studio běží na stejném počítači jako Spice Harvester. Co udělat: obvykle stačí ponechat tuto výchozí API adresu:")
                    .foregroundStyle(palette.textPrimary)

                helpCode("http://localhost:1234/v1/chat/completions")

                Text("Kontrolní body:")
                    .foregroundStyle(palette.textPrimary)

                helpStep("Model je načtený a připravený k inferenci.")
                helpStep("Server opravdu běží (ne jen otevřené okno aplikace).")
                helpStep("LM Studio vystavuje OpenAI-kompatibilní API adresu na portu 1234 nebo na portu, který sis zvolil.")
                helpStep("Pokud máš v LM Studiu zapnuté vyžadování tokenu, vyplň ho v Nastavení do pole LM Studio API token.")
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .lineSpacing(4)
        }
    }

    private var preflightChecksSection: some View {
        section(
            title: "Kontroly před zahájením",
            subtitle: "Co aplikace ověří před spuštěním a proč je to důležité.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Situace: ještě před samotnou analýzou aplikace provede rychlou kontrolu. Co to znamená: včas tě upozorní na problém, který by mohl způsobit chybu nebo slabý výsledek.")
                    .foregroundStyle(palette.textPrimary)

                helpStep("Kontrola 1: LM Studio odpovídá a je dostupný aktivní model.")
                helpStep("Kontrola 2: model je skutečně načtený a je vhodný pro textovou analýzu. Embedovací model pro tuto úlohu nestačí.")
                helpStep("Kontrola 3: aplikace zjistí reálně načtený kontext modelu.")
                helpStep("Kontrola 4: ze vstupu se odhadne počet tokenů. U složky se jako orientační vzorek použije největší podporovaný soubor.")
                helpStep("Kontrola 5: vypočítá se odhad počtu bloků, pokud je zapnuté dělení textu na bloky.")
                helpStep("Kontrola 6: u PDF se ověří kvalita extrakce textu.")
                helpStep("Kontrola 7: podle nastavení se ověří i Qdrant.")

                Text("Příklad: když vidíš Odhad vstupu: ~3200 tokenů / kontext 4096, znamená to, že dokument je blízko limitu modelu. Co udělat: zkrátit vstup, zkrátit prompt nebo zvýšit kontext modelu.")
                    .foregroundStyle(palette.textPrimary)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .lineSpacing(4)
        }
    }

    private var remoteLMStudioSection: some View {
        section(
            title: "LM Studio na jiném počítači",
            subtitle: "Použití přes lokální síť nebo jinak dostupný vzdálený stroj.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aplikace umí používat i LM Studio spuštěné na jiném počítači. Do pole LM Studio API adresa zadej adresu vzdáleného stroje místo localhostu, například:")
                    .foregroundStyle(palette.textPrimary)

                helpCode("http://192.168.1.50:1234/v1/chat/completions")
                helpCode("http://lmstudio-pc.local:1234/v1/chat/completions")

                Text("Na vzdáleném počítači musí být splněné tyto podmínky:")
                    .foregroundStyle(palette.textPrimary)

                helpStep("LM Studio server musí běžet a musí naslouchat i pro síťová připojení, ne jen pro localhost.")
                helpStep("Počítač se Spice Harvesterem musí vzdálený stroj vidět po síti.")
                helpStep("Firewall na vzdáleném počítači musí povolit příchozí spojení na port LM Studia, typicky 1234.")
                helpStep("Musíš znát správnou IP adresu nebo hostname vzdáleného počítače.")

                Text("Projekt je už upravený tak, aby aplikace mohla používat i nešifrované HTTP API adresy v lokální síti.")
                    .foregroundStyle(palette.textPrimary)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .lineSpacing(4)
        }
    }

    private var heartbeatSection: some View {
        section(
            title: "Průběžný monitoring spojení",
            subtitle: "Jak aplikace hlídá dostupnost serveru.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Aplikace průběžně kontroluje dostupnost LM Studio a Qdrantu pomocí lehkého pingu. Díky tomu okamžitě uvidíš, když server přestane odpovídat.")
                    .foregroundStyle(palette.textPrimary)

                helpStep("V diagnostickém panelu se zobrazuje aktuální latence: Připojeno · 42 ms.")
                helpStep("Pokud server přestane odpovídat, badge přejde do chybového stavu s počtem selhání.")
                helpStep("Po obnovení spojení se stav automaticky vrátí na zelený a aplikace znovu načte informace o modelu.")
                helpStep("Monitoring běží jen když je okno aplikace aktivní. Na pozadí se šetří síť.")
                helpStep("Interval: každých 10 sekund v klidu, každých 5 sekund během zpracování.")
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .lineSpacing(4)
        }
    }

    private var resumeSection: some View {
        section(
            title: "Pokračování v přerušeném běhu",
            subtitle: "Co se stane, když zpracování přerušíš.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pokud zpracování přerušíš (tlačítkem Stop nebo zavřením aplikace), uloží se checkpoint s informací o tom, které soubory už jsou hotové.")
                    .foregroundStyle(palette.textPrimary)

                helpStep("Při dalším spuštění se zobrazí možnost Pokračovat v nedokončeném běhu.")
                helpStep("Kliknutím na Pokračovat se přeskočí již zpracované soubory a běh pokračuje od místa přerušení.")
                helpStep("Kliknutím na Zahodit a začít znovu se checkpoint smaže a zpracování začne od začátku.")
                helpStep("Po úspěšném dokončení celé dávky se checkpoint automaticky smaže.")
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .lineSpacing(4)
        }
    }

    private var workflowSection: some View {
        section(
            title: "Co dělají jednotlivá pole",
            subtitle: "Podrobné vysvětlení hlavního okna krok za krokem.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 8) {
                helpStep("Složky: pole Vstup/Výstup jsou klikací výběr složky. Pole nejsou určená pro ruční psaní cesty.")
                helpStep("Po výběru se v poli zobrazí plná cesta ke složce. Cesta se hned validuje na existující složku.")
                helpStep("Diagnostika: průběžně kontroluje, jestli je LM Studio dostupné, jestli je načtený správný model a jestli dokument není příliš dlouhý pro aktuální kontext modelu.")
                helpStep("Prompt: to je tvoje zadání pro model. Můžeš ho napsat ručně, nebo načíst z `.txt/.md` tlačítkem Načti prompt ze souboru.")
                helpStep("Důležité: pro běh je vždy rozhodující obsah prompt textového okna. Po načtení ze souboru můžeš text dál ručně upravit.")
                helpStep("Timeout: jak dlouho má aplikace čekat na odpověď modelu pro jeden požadavek.")
                helpStep("Souběžné požadavky: kolik částí práce poběží najednou. Vyšší číslo bývá rychlejší, ale více zatěžuje počítač i model.")
                helpStep("Rychlý režim: jedním přepínačem nastaví bezpečnou rychlou kombinaci voleb pro běžné dávkové zpracování.")
                helpStep("Streamovat odpověď: když to model podporuje, odpověď přichází postupně po částech.")
                helpStep("Úsporný výstup: model se drží kratší a věcnější odpovědi.")
                helpStep("Dělit text na bloky: automatika ho zapíná/vypíná podle odhadu délky vstupu a kontextu modelu.")
                helpStep("Celkový souhrn dávky: když je zapnutý, po dokončení všech souborů vznikne ještě jeden společný souhrn přes celou dávku.")
                helpStep("Spuštění: tady běh spustíš tlačítkem Spustit prompt. Během běhu vidíš průběh, počet požadavků, typ aktuálního kroku a můžeš zpracování kdykoliv zastavit.")
                helpStep("Pokročilé volby pro Qdrant a volitelný LM Studio API token jsou v okně Nastavení.")
            }
        }
    }

    private var processingBehaviorSection: some View {
        section(
            title: "Jak se aplikace chová při zpracování",
            subtitle: "Co uvidíš během běhu a jak to správně číst.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Situace: krátký soubor obvykle znamená jeden požadavek a jeden výsledek. U delšího dokumentu aplikace pracuje po částech, aby se vešla do limitu modelu.")
                    .foregroundStyle(palette.textPrimary)

                helpStep("Když je zapnuté dělení textu na bloky, dokument se rozdělí na menší části a odešle se postupně.")
                helpStep("Když vidíš Aktuální blok: 3 / 12, není to restart. Je to třetí část ze dvanácti v rámci stejného souboru.")
                helpStep("Po dokončení bloků aplikace sestaví jeden výsledný text za soubor.")
                helpStep("Když model narazí na limit kontextu, aplikace zmenší vstup a požadavek zopakuje.")
                helpStep("Po stisku Zastavit se aktivní požadavky ukončí a uloží se checkpoint pro pozdější pokračování.")
                helpStep("Když Qdrant není dostupný, aplikace může pokračovat bez něj. Při dočasném výpadku se automaticky zkusí znovu (až 3 pokusy s rostoucím intervalem).")
                helpStep("Na konci vždy vznikne vystup--...txt (seznam výsledků po souborech). Soubor souhrn--...txt vznikne jen při zapnutém přepínači Celkový souhrn dávky.")
                helpStep("Pokud je aktivní ruční override bloků, můžeš se vrátit na automatiku tlačítkem Zapnout automatiku bloků přímo v části Režimy.")
                helpStep("Stavové čítače jsou záměrně filtrované, takže se mohou měnit po větších krocích místo každého dílčího požadavku.")

                Text("Jednoduše řečeno: varování znamená spustit lze, ale pozor. Chyba znamená nejdřív oprav nastavení nebo model.")
                    .foregroundStyle(palette.textPrimary)
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .lineSpacing(4)
        }
    }

    private var troubleshootingSection: some View {
        section(
            title: "Když něco nefunguje",
            subtitle: "Rychlé postupy: co problém znamená a co udělat hned.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 8) {
                helpStep("Aplikace nic neposílá modelu: obvykle neběží LM Studio server nebo je špatná API adresa. V Nastavení klikni na Test připojení.")
                helpStep("Vzdálený server neodpovídá: nejčastěji je problém v síti. Zkontroluj IP/hostname, port a firewall na vzdáleném počítači.")
                helpStep("Heartbeat ukazuje chybu: diagnostický badge zobrazuje počet selhání za sebou. Zkontroluj, zda server běží a je dostupný.")
                helpStep("Model se nenajde: model není načtený v LM Studiu. V LM Studiu model ručně načti.")
                helpStep("Diagnostika ukazuje načteno 4096: model má malý kontext. V LM Studiu zvyš načtený kontext.")
                helpStep("Diagnostika ukazuje vysoké riziko: vstup je moc velký vůči limitu modelu. Zkrať prompt nebo analyzuj menší část dokumentu.")
                helpStep("Prompt ze souboru se nenačetl: ověř, že je to existující `.txt` nebo `.md` soubor a že není prázdný.")
                helpStep("PDF hlásí slabou extrakci: soubor je často sken bez textové vrstvy. Ověř, že je text v PDF skutečně čitelný.")
                helpStep("Zpracování je pomalé: model je přetížený. Zapni Rychlý režim a případně sniž počet souběžných požadavků.")
                helpStep("Qdrant hlásí nesoulad konfigurace: kolekce neodpovídá aktuálnímu profilu. Nech zapnutou automatickou správu konfigurace RAG.")
                helpStep("Po stisku Zastavit vznikl jen částečný výstup: to je v pořádku. Příště můžeš pokračovat od místa přerušení díky checkpointu.")
            }
        }
    }

    private var formatsSection: some View {
        section(
            title: "Podporované soubory",
            subtitle: "Co aplikace umí přečíst hned a co je potřeba převést.",
            palette: palette
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Bez převodu fungují: textové soubory (.txt, .md, .csv, .json, .xml, .yaml, .yml, .html, .htm, .toml, .ini, .cfg, .conf, .env, .properties).")
                Text("Bez převodu fungují i kancelářské dokumenty: .doc, .docx, .odt.")
                Text("PDF funguje také. U skenů bez textové vrstvy se použije OCR fallback.")
                Text("Podporované jsou i zdrojové kódy a skripty: .swift, .py, .js, .ts, .java, .cpp, .c, .cs, .sql, .pls, .pck, .pkb, .pks, .prc, .vw, .trg, .fnc, .psql.")
                Text("Co je potřeba převést předem: .ppt/.pptx a .xls/.xlsx (soubor je rozpoznaný, ale obsah se zatím přímo neextrahuje).")
            }
            .font(.system(size: 14, weight: .medium, design: .rounded))
            .foregroundStyle(palette.textPrimary)
            .lineSpacing(4)
            .textSelection(.enabled)
        }
    }

    private var closeHelpButton: some View {
        HStack {
            Spacer()
            Button("Zavřít") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.top, 4)
    }

    private func helpStep(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(palette.accent.opacity(0.85))
                .frame(width: 6, height: 6)
                .padding(.top, 7)

            Text(text)
                .foregroundStyle(palette.textPrimary)
        }
        .font(.system(size: 14, weight: .medium, design: .rounded))
        .lineSpacing(4)
    }

    private func helpCode(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold, design: .monospaced))
            .foregroundStyle(palette.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(palette.border, lineWidth: 1)
                    )
            )
            .textSelection(.enabled)
    }

    private func section<Content: View>(
        title: String,
        subtitle: String?,
        palette: GlassPalette,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GlassSection(title: title, subtitle: subtitle, palette: palette, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
