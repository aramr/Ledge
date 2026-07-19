import AppKit
import EventKit
import Foundation

@MainActor
final class CalendarService {
    private let store = EKEventStore()
    private var storeObserver: NSObjectProtocol?
    private var selectedDate = Calendar.current.startOfDay(for: .now)
    private var displayedMonth = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .now

    var onAccessStateChange: ((CalendarAccessState) -> Void)?
    var onEventsChange: (([CalendarEventItem]) -> Void)?

    func start() {
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }

        updateAuthorizationState()
    }

    func stop() {
        if let storeObserver {
            NotificationCenter.default.removeObserver(storeObserver)
        }
        storeObserver = nil
    }

    func requestAccess() {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            updateAuthorizationState()
            return
        }

        onAccessStateChange?(.requesting)
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                onAccessStateChange?(granted ? .authorized : .denied)
                if granted { reload() }
            } catch {
                onAccessStateChange?(.denied)
            }
        }
    }

    func updateSelection(date: Date, displayedMonth: Date) {
        selectedDate = Calendar.current.startOfDay(for: date)
        self.displayedMonth = displayedMonth
        reload()
    }

    private func updateAuthorizationState() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            onAccessStateChange?(.authorized)
            reload()
        case .denied, .restricted, .writeOnly:
            onAccessStateChange?(.denied)
            onEventsChange?([])
        case .notDetermined:
            onAccessStateChange?(.unknown)
        @unknown default:
            onAccessStateChange?(.denied)
        }
    }

    private func reload() {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }

        let calendar = Calendar.current
        guard let monthInterval = calendar.dateInterval(of: .month, for: displayedMonth),
              let start = calendar.date(byAdding: .day, value: -7, to: monthInterval.start),
              let end = calendar.date(byAdding: .day, value: 7, to: monthInterval.end) else {
            return
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let items = store.events(matching: predicate)
            .map(Self.makeItem)
            .sorted { lhs, rhs in
                if lhs.startDate == rhs.startDate { return lhs.title < rhs.title }
                return lhs.startDate < rhs.startDate
            }
        onEventsChange?(items)
    }

    private static func makeItem(from event: EKEvent) -> CalendarEventItem {
        let color = NSColor(cgColor: event.calendar.cgColor)?
            .usingColorSpace(.deviceRGB) ?? .systemBlue
        return CalendarEventItem(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title?.isEmpty == false ? event.title : "Untitled event",
            startDate: event.startDate,
            endDate: event.endDate,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar.title,
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent
        )
    }
}
