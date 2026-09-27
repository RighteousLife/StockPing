import Foundation
import SwiftUI

@MainActor
final class ProductOrganizationStore: ObservableObject {
    static let shared = ProductOrganizationStore()

    private let groupsStorageKey = "productGroups.v1"
    private let tagsStorageKey = "productTags.v1"

    @Published private(set) var availableGroups: [String] = []
    @Published private(set) var availableTags: [String] = []

    private init() {
        loadData()
    }

    // MARK: - Groups Management

    func createGroup(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !availableGroups.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return false
        }
        availableGroups.append(trimmed)
        availableGroups.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        saveData()
        return true
    }

    func renameGroup(from oldName: String, to newName: String, in products: inout [TrackedProduct]) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let index = availableGroups.firstIndex(where: { $0.caseInsensitiveCompare(oldName) == .orderedSame }) else {
            return false
        }

        availableGroups[index] = trimmed
        availableGroups.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

        for i in products.indices {
            if products[i].group?.caseInsensitiveCompare(oldName) == .orderedSame {
                products[i].group = trimmed
            }
        }

        saveData()
        TrackedProductStore.save(products)
        return true
    }

    func deleteGroup(_ name: String, in products: inout [TrackedProduct]) {
        availableGroups.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        for i in products.indices {
            if products[i].group?.caseInsensitiveCompare(name) == .orderedSame {
                products[i].group = nil
            }
        }
        saveData()
        TrackedProductStore.save(products)
    }

    func assignGroup(_ group: String?, to productID: UUID, in products: inout [TrackedProduct]) {
        guard let index = products.firstIndex(where: { $0.id == productID }) else { return }
        let trimmed = group?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalGroup = (trimmed?.isEmpty ?? true) ? nil : trimmed

        if let finalGroup, !availableGroups.contains(where: { $0.caseInsensitiveCompare(finalGroup) == .orderedSame }) {
            availableGroups.append(finalGroup)
            availableGroups.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        products[index].group = finalGroup
        saveData()
        TrackedProductStore.save(products)
    }

    // MARK: - Tags Management

    func createTag(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !availableTags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return false
        }
        availableTags.append(trimmed)
        availableTags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        saveData()
        return true
    }

    func deleteTag(_ name: String, in products: inout [TrackedProduct]) {
        availableTags.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        for i in products.indices {
            products[i].tags.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
        }
        saveData()
        TrackedProductStore.save(products)
    }

    func addTag(_ tag: String, to productID: UUID, in products: inout [TrackedProduct]) {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = products.firstIndex(where: { $0.id == productID }) else { return }

        if !products[index].tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            products[index].tags.append(trimmed)
        }

        if !availableTags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            availableTags.append(trimmed)
            availableTags.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }

        saveData()
        TrackedProductStore.save(products)
    }

    func removeTag(_ tag: String, from productID: UUID, in products: inout [TrackedProduct]) {
        guard let index = products.firstIndex(where: { $0.id == productID }) else { return }
        products[index].tags.removeAll { $0.caseInsensitiveCompare(tag) == .orderedSame }
        TrackedProductStore.save(products)
    }

    func syncFromProducts(_ products: [TrackedProduct]) {
        var groupsSet = Set(availableGroups)
        var tagsSet = Set(availableTags)

        for product in products {
            if let group = product.group, !group.isEmpty {
                groupsSet.insert(group)
            }
            for tag in product.tags where !tag.isEmpty {
                tagsSet.insert(tag)
            }
        }

        availableGroups = Array(groupsSet).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        availableTags = Array(tagsSet).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        saveData()
    }

    private func loadData() {
        if let data = UserDefaults.standard.stringArray(forKey: groupsStorageKey) {
            availableGroups = data.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        if let data = UserDefaults.standard.stringArray(forKey: tagsStorageKey) {
            availableTags = data.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    private func saveData() {
        UserDefaults.standard.set(availableGroups, forKey: groupsStorageKey)
        UserDefaults.standard.set(availableTags, forKey: tagsStorageKey)
    }
}
