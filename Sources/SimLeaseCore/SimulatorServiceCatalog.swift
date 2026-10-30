import Foundation

public struct SimulatorServiceCategory: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let downside: String
    public let approxMemoryMB: Int
    public let labels: [String]
    public let alwaysEnabled: [String]
}

public enum SimulatorServiceCatalogError: Error, Equatable, CustomStringConvertible {
    case unknownCategory(String)

    public var description: String {
        switch self {
        case .unknownCategory(let id): "unknown service category \(id); run simlease device slim --list"
        }
    }
}

public enum SimulatorServiceCatalog {
    public static let categories: [SimulatorServiceCategory] = [
        SimulatorServiceCategory(id: "widgets", name: "Widgets & Wallpaper", downside: "Home and Lock Screen widgets, wallpaper posters, and Live Activities stop updating.", approxMemoryMB: 675,
            labels: ["com.apple.PosterBoard", "com.apple.chronod", "com.apple.liveactivitiesd", "com.apple.navd"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "siri", name: "Siri & Intelligence", downside: "Siri, speech features, and Apple Intelligence services are unavailable.", approxMemoryMB: 265,
            labels: ["com.apple.assistant_cdmd", "com.apple.assistant_service", "com.apple.siriactionsd", "com.apple.siriinferenced", "com.apple.siriknowledged", "com.apple.sirittsd", "com.apple.siri.context.service", "com.apple.siri.acousticsignature", "com.apple.corespeechd", "com.apple.voiced", "com.apple.voicebankingd", "com.apple.speechmodeltrainingd", "com.apple.intelligenceplatformd", "com.apple.intelligencecontextd", "com.apple.intelligenceflowd", "com.apple.intelligencetasksd", "com.apple.generativeexperiencesd", "com.apple.knowledgeconstructiond", "com.apple.naturallanguaged", "com.apple.textunderstandingd", "com.apple.modelcatalogd", "com.apple.modelmanagerd", "com.apple.mlhostd", "com.apple.mlruntimed", "com.apple.suggestd", "com.apple.parsecd", "com.apple.parsec-fbf", "com.apple.proactiveeventtrackerd"],
            alwaysEnabled: ["com.apple.assistantd"]),
        SimulatorServiceCategory(id: "search", name: "Spotlight & Search", downside: "Spotlight and Settings search return no results, and Recents in Files and the document picker fails to load.", approxMemoryMB: 50,
            labels: ["com.apple.searchd", "com.apple.searchtoold", "com.apple.spotlightknowledged", "com.apple.spotlightknowledged.updater", "com.apple.corespotlightservice"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "icloud", name: "iCloud & Apple Account", downside: "iCloud sync, Apple Account, Keychain, and backup workflows will not work.", approxMemoryMB: 100,
            labels: ["com.apple.appleaccountd", "com.apple.appleaccounttransparencyd", "com.apple.appleidsetupd", "com.apple.akd", "com.apple.amsaccountsd", "com.apple.amsengagementd", "com.apple.amsondevicestoraged", "com.apple.cloudd", "com.apple.cloudphotod", "com.apple.ckdiscretionaryd", "com.apple.cloudsettingssyncagent", "com.apple.bird", "com.apple.syncdefaultsd", "com.apple.cdpd", "com.apple.sosd", "com.apple.SecureBackupDaemon", "com.apple.TrustedPeersHelper", "com.apple.protectedcloudstorage.protectedcloudkeysyncing", "com.apple.icloudmailagent", "com.apple.icloudsubscriptionoptimizerd", "com.apple.communicationtrustd"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "store", name: "App Store, Push & Media", downside: "Remote push notifications and StoreKit or App Store testing will not work.", approxMemoryMB: 80,
            labels: ["com.apple.appstored", "com.apple.appstorecomponentsd", "com.apple.apsd", "com.apple.itunescloudd", "com.apple.itunesstored", "com.apple.storekitd", "com.apple.amsaccountsd", "com.apple.amsengagementd", "com.apple.amsondevicestoraged", "com.apple.passd", "com.apple.financed", "com.apple.videosubscriptionsd", "com.apple.assetsubscriptiond", "com.apple.musicd"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "pim", name: "Mail, Calendar & Contacts", downside: "Contacts, Calendar, Reminders, and Mail-backed pickers or sync may fail.", approxMemoryMB: 80,
            labels: ["com.apple.email.maild", "com.apple.exchangesyncd", "com.apple.dataaccess.dataaccessd", "com.apple.calaccessd", "com.apple.remindd", "com.apple.contactsd", "com.apple.contacts.postersyncd", "com.apple.peopled"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "web", name: "Safari Sync & Web Services", downside: "Universal links and Safari sync or background web services will not work.", approxMemoryMB: 50,
            labels: ["com.apple.SafariBookmarksSyncAgent", "com.apple.Safari.History", "com.apple.Safari.passwordbreachd", "com.apple.Safari.SafeBrowsing.Service", "com.apple.safarifetcherd", "com.apple.WebBookmarks.webbookmarksd", "com.apple.webkit.adattributiond", "com.apple.webkit.webpushd", "com.apple.webprivacyd", "com.apple.swcd"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "family", name: "Family & Screen Time", downside: "Family Sharing, Screen Time, and usage tracking stop working.", approxMemoryMB: 65,
            labels: ["com.apple.familycircled", "com.apple.FamilyControlsAgent", "com.apple.familynotification", "com.apple.askpermissiond", "com.apple.asktod", "com.apple.ScreenTimeAgent", "com.apple.ScreenTimeSettingsAgent", "com.apple.UsageTrackingAgent"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "health", name: "Health, Home & Fitness", downside: "HealthKit, HomeKit, and Fitness integrations will not work.", approxMemoryMB: 135,
            labels: ["com.apple.healthd", "com.apple.healthappd", "com.apple.healthcontentd", "com.apple.healtheventsd", "com.apple.healthrecordsd", "com.apple.finhealthd", "com.apple.homed", "com.apple.homeeventsd", "com.apple.fitcore", "com.apple.fitcore.session", "com.apple.fitnesscoachingd", "com.apple.fitnessintelligenced", "com.apple.activityawardsd", "com.apple.activitysharingd"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "photos", name: "Photos & Media Analysis", downside: "Photo picker, Photos-library workflows, and media analysis may fail.", approxMemoryMB: 60,
            labels: ["com.apple.photoanalysisd", "com.apple.photosface", "com.apple.mediaanalysisd", "com.apple.mediaanalysisd.service", "com.apple.mediastream.mstreamd", "com.apple.medialibraryd", "com.apple.assetsd", "com.apple.assetsd.nebulad"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "apps", name: "News, Weather, Maps & Games", downside: "News, Weather, Maps background data, and game-controller services are unavailable.", approxMemoryMB: 90,
            labels: ["com.apple.newsd", "com.apple.weatherd", "com.apple.Maps.mapssyncd", "com.apple.Maps.mapspushd", "com.apple.Maps.geocorrectiond", "com.apple.maps.destinationd", "com.apple.MapKit.SnapshotService", "com.apple.jetpackassetd", "com.apple.tipsd", "com.apple.gamesaved", "com.apple.GameController.gamecontrollerd"],
            alwaysEnabled: ["com.apple.gamed"]),
        SimulatorServiceCategory(id: "messaging", name: "Messaging & FaceTime", downside: "iMessage, FaceTime, and related identity services will not work.", approxMemoryMB: 60,
            labels: ["com.apple.identityservicesd", "com.apple.ids_simd", "com.apple.imautomatichistorydeletionagent", "com.apple.imcore.imtransferagent", "com.apple.imdpersistence.IMDPersistenceAgent", "com.apple.facetimemessagestored", "com.apple.telephonyutilities.callservicesd"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "connectivity", name: "Sharing & Device Connectivity", downside: "AirDrop, Continuity, CarPlay, Watch, and Find My connectivity will not work.", approxMemoryMB: 65,
            labels: ["com.apple.rapportd", "com.apple.companiond", "com.apple.carkitd", "com.apple.wcd", "com.apple.tvremoted", "com.apple.avatarsd", "com.apple.stickersd", "com.apple.sociallayerd", "com.apple.announced", "com.apple.navd", "com.apple.findmy.findmylocated"],
            alwaysEnabled: ["com.apple.sharingd"]),
        SimulatorServiceCategory(id: "telemetry", name: "Ads, Diagnostics & Telemetry", downside: "DeviceCheck plus analytics, diagnostics, and feedback services are unavailable.", approxMemoryMB: 105,
            labels: ["com.apple.ap.adprivacyd", "com.apple.ap.promotedcontentd", "com.apple.diagnosticextensionsd", "com.apple.feedbackd", "com.apple.rtcreportingd", "com.apple.securityuploadd", "com.apple.geoanalyticsd", "com.apple.triald", "com.apple.followupd", "com.apple.purplebuddy.budd", "com.apple.devicecheckd"],
            alwaysEnabled: []),
        SimulatorServiceCategory(id: "other", name: "Other Background Services", downside: "Wallet, merchant, business, asset, and miscellaneous background services are unavailable.", approxMemoryMB: 195,
            labels: ["com.apple.financed", "com.apple.passd", "com.apple.merchantd", "com.apple.coreidvd", "com.apple.businessservicesd", "com.apple.deviceaccessd", "com.apple.replicatord", "com.apple.linkd", "com.apple.ind", "com.apple.storagedatad", "com.apple.StatusKitAgent", "com.apple.countryd", "com.apple.mobileassetd", "com.apple.managedconfiguration.passcodenagd"],
            alwaysEnabled: []),
    ]

    public static let protectedLabels: Set<String> = Set(["com.apple.SpringBoard", "com.apple.backboardd"] + categories.flatMap(\.alwaysEnabled))

    public static let managed: Set<String> = Set(categories.flatMap { $0.labels + $0.alwaysEnabled })

    public static func desired(keep: Set<String>) throws -> Set<String> {
        let known = Set(categories.map(\.id))
        if let unknown = keep.sorted().first(where: { !known.contains($0) }) { throw SimulatorServiceCatalogError.unknownCategory(unknown) }
        let kept = Set(categories.filter { keep.contains($0.id) }.flatMap(\.labels))
        return Set(categories.flatMap(\.labels)).subtracting(kept).subtracting(protectedLabels)
    }

    public static func delta(current: Set<String>, desired: Set<String>) -> (disable: [String], enable: [String]) {
        (desired.intersection(managed).subtracting(current).sorted(), current.intersection(managed).subtracting(desired).sorted())
    }

    public static func parseDisabled(_ output: String) -> Set<String> {
        var labels = Set<String>()
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: .whitespaces)
            guard label.count > 2, label.hasPrefix("\""), label.hasSuffix("\"") else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("disabled") || value.hasPrefix("true") { labels.insert(String(label.dropFirst().dropLast())) }
        }
        return labels
    }

    public static func supportsPersistentOverrides(runtime: String) -> Bool {
        let parts = (runtime.components(separatedBy: "SimRuntime.").last ?? runtime).split(separator: "-")
        guard parts.count >= 3, parts[0] == "iOS", let major = Int(parts[1]), let minor = Int(parts[2]) else { return false }
        return major > 18 || major == 18 && minor >= 5
    }
}
