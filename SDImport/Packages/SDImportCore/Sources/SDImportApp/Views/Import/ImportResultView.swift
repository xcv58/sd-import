import SDImportCore
import SwiftUI

struct ImportResultView: View {
    let result: ImportResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import Result")
                .font(.headline)
            HStack(spacing: 20) {
                MetricView(title: "Imported", value: result.importedFiles)
                MetricView(title: "Skipped", value: result.skippedFiles)
                MetricView(title: "Failed", value: result.failedFiles)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
