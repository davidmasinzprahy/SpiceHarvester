import Foundation

struct SHExtractionResult: Codable, Hashable, Sendable {
    var source_file: String
    var patient_name: String
    var patient_id: String
    var birth_date: String
    var admission_date: String
    var discharge_date: String
    var diagnoses: [String]
    var medication: [String]
    var lab_values: [String]
    var discharge_status: String
    var warnings: [String]
    var confidence: Double
    /// Raw LLM response as it arrived from the model, before strict schema validation.
    /// Always populated so the user can inspect what the model actually produced –
    /// especially useful when the prompt defines a custom schema that doesn't match
    /// the canonical `SHExtractionResult` fields.
    var rawResponse: String

    init(
        source_file: String,
        patient_name: String,
        patient_id: String,
        birth_date: String,
        admission_date: String,
        discharge_date: String,
        diagnoses: [String],
        medication: [String],
        lab_values: [String],
        discharge_status: String,
        warnings: [String],
        confidence: Double,
        rawResponse: String = ""
    ) {
        self.source_file = source_file
        self.patient_name = patient_name
        self.patient_id = patient_id
        self.birth_date = birth_date
        self.admission_date = admission_date
        self.discharge_date = discharge_date
        self.diagnoses = diagnoses
        self.medication = medication
        self.lab_values = lab_values
        self.discharge_status = discharge_status
        self.warnings = warnings
        self.confidence = confidence
        self.rawResponse = rawResponse
    }

    enum CodingKeys: String, CodingKey {
        case source_file, patient_name, patient_id
        case birth_date, admission_date, discharge_date
        case diagnoses, medication, lab_values
        case discharge_status, warnings, confidence, rawResponse
    }

    /// Lenient decoding – missing fields default to empty values. Strict validation is
    /// the job of `SHResultSchemaValidator`; the decoder alone never fails just because
    /// a field is absent, so we can still pick up whatever the LLM returned.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source_file = try c.decodeIfPresent(String.self, forKey: .source_file) ?? ""
        patient_name = try c.decodeIfPresent(String.self, forKey: .patient_name) ?? ""
        patient_id = try c.decodeIfPresent(String.self, forKey: .patient_id) ?? ""
        birth_date = try c.decodeIfPresent(String.self, forKey: .birth_date) ?? ""
        admission_date = try c.decodeIfPresent(String.self, forKey: .admission_date) ?? ""
        discharge_date = try c.decodeIfPresent(String.self, forKey: .discharge_date) ?? ""
        diagnoses = try c.decodeIfPresent([String].self, forKey: .diagnoses) ?? []
        medication = try c.decodeIfPresent([String].self, forKey: .medication) ?? []
        lab_values = try c.decodeIfPresent([String].self, forKey: .lab_values) ?? []
        discharge_status = try c.decodeIfPresent(String.self, forKey: .discharge_status) ?? ""
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
        confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0
        rawResponse = try c.decodeIfPresent(String.self, forKey: .rawResponse) ?? ""
    }

    static func empty(sourceFile: String) -> SHExtractionResult {
        SHExtractionResult(
            source_file: sourceFile,
            patient_name: "",
            patient_id: "",
            birth_date: "",
            admission_date: "",
            discharge_date: "",
            diagnoses: [],
            medication: [],
            lab_values: [],
            discharge_status: "",
            warnings: [],
            confidence: 0,
            rawResponse: ""
        )
    }

    mutating func merge(with partial: SHExtractionResult) {
        patient_name = patient_name.isEmpty ? partial.patient_name : patient_name
        patient_id = patient_id.isEmpty ? partial.patient_id : patient_id
        birth_date = birth_date.isEmpty ? partial.birth_date : birth_date
        admission_date = admission_date.isEmpty ? partial.admission_date : admission_date
        discharge_date = discharge_date.isEmpty ? partial.discharge_date : discharge_date
        if diagnoses.isEmpty { diagnoses = partial.diagnoses }
        if medication.isEmpty { medication = partial.medication }
        if lab_values.isEmpty { lab_values = partial.lab_values }
        discharge_status = discharge_status.isEmpty ? partial.discharge_status : discharge_status
        warnings.append(contentsOf: partial.warnings)

        if confidence == 0 {
            confidence = partial.confidence
        } else if partial.confidence > 0 {
            confidence = (confidence + partial.confidence) / 2.0
        }

        if !partial.rawResponse.isEmpty {
            rawResponse += (rawResponse.isEmpty ? "" : "\n---\n") + partial.rawResponse
        }
    }
}
