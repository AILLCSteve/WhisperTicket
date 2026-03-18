import SwiftUI

struct TableSelectView: View {
    @Environment(\.appServices) var services
    @State private var vm: TableSelectViewModel?
    @State private var navigateToSession: Bool = false
    @State private var customTable: String = ""

    private let presetTables = ["1","2","3","4","5","6","7","8","9","10","11","12","Bar","Patio"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Select Table")
                    .font(.largeTitle.bold())
                    .padding(.top)

                // Custom entry
                HStack {
                    TextField("Table # or Name", text: $customTable)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.default)
                    Button("Go") {
                        guard !customTable.isEmpty else { return }
                        vm?.selectTable(customTable)
                        navigateToSession = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(customTable.isEmpty || vm == nil)
                }
                .padding(.horizontal)

                // Preset grid
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70))], spacing: 12) {
                    ForEach(presetTables, id: \.self) { table in
                        Button(table) {
                            vm?.selectTable(table)
                            navigateToSession = true
                        }
                        .buttonStyle(.bordered)
                        .font(.title2.bold())
                        .frame(height: 60)
                        .disabled(vm == nil)
                    }
                }
                .padding(.horizontal)

                // Recent tables
                if let recent = vm?.recentTables, !recent.isEmpty {
                    VStack(alignment: .leading) {
                        Text("Recent").font(.headline).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack {
                                ForEach(recent, id: \.self) { table in
                                    Button(table) {
                                        vm?.selectTable(table)
                                        navigateToSession = true
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }

                Spacer()
            }
            .navigationDestination(isPresented: $navigateToSession) {
                if let tableNumber = vm?.tableNumber, !tableNumber.isEmpty {
                    LiveSessionView(tableNumber: tableNumber)
                }
            }
            .task {
                let newVm = TableSelectViewModel(repository: services.repository)
                vm = newVm
                await newVm.loadRecentTables()
            }
        }
    }
}
