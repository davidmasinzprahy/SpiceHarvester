# Legacy Runtime

Tato složka obsahuje původní implementaci aplikace, která byla vyřazena z aktivního targetu.

Důvod přesunu:
- zjednodušení údržby
- oddělení staré a nové architektury
- odstranění kompilace nepoužívaných částí

## Stav

- Soubory v `Legacy/` nejsou součástí aktivního runtime.
- Aktivní implementace je ve složce `SpiceHarvester/` (`Models`, `ViewModels`, `Services`, `Pipeline`, `Cache`, `Logging`, `Export`, `Views`).

## Mapa legacy -> nový ekvivalent

- `Legacy/BatchOrchestrator.swift` -> `SpiceHarvester/Pipeline/SHPreprocessingPipeline.swift`, `SpiceHarvester/Pipeline/SHExtractionPipeline.swift`
- `Legacy/AnalysisService.swift` -> `SpiceHarvester/Services/SHOpenAICompatibleClient.swift`, `SpiceHarvester/Pipeline/SHExtractionPipeline.swift`
- `Legacy/ExtractionService.swift` -> `SpiceHarvester/Services/SHPDFParser.swift`, `SpiceHarvester/Services/SHOCRProvider.swift`, `SpiceHarvester/Services/SHTextCleaningService.swift`
- `Legacy/ContentViewModel.swift` (smazán z aktivního targetu) -> `SpiceHarvester/ViewModels/SHAppViewModel.swift`
- `Legacy/PipelineProfile.swift` -> `SpiceHarvester/Models/SHAppConfig.swift` + runtime parametry ve `SHAppViewModel`
- `Legacy/PreprocessingProfile.swift` -> `SpiceHarvester/Services/SHTextCleaningService.swift` + prompt workflows v `SHPromptLibraryService`
- `Legacy/DiagnosticsService.swift` -> `SpiceHarvester/Services/SHOpenAICompatibleClient.swift` + status handling v `SHAppViewModel`
- `Legacy/DeduplicationCache.swift` -> `SpiceHarvester/Cache/SHCacheManager.swift`
- `Legacy/XLSXWriter.swift` -> `SpiceHarvester/Export/SHExportService.swift` + `SHXLSXExporting`
- `Legacy/LMStudioStreamHandler.swift` -> zjednodušeno na request/response přes `URLSession` v `SHOpenAICompatibleClient`
- `Legacy/AboutView.swift`, `Legacy/Settingsview.swift`, `Legacy/GlassUI.swift` -> nové jednoduché blokové UI v `SpiceHarvester/ContentView.swift`

## Poznámka

Tato složka je archivní. Nové změny dělej pouze v aktivních modulech.
