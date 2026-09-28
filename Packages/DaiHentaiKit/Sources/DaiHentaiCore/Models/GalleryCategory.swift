import Foundation

/// The ten gallery categories the site knows about.
public enum GalleryCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case doujinshi = "Doujinshi"
    case manga = "Manga"
    case artistCG = "Artist CG"
    case gameCG = "Game CG"
    case western = "Western"
    case nonH = "Non-H"
    case imageSet = "Image Set"
    case cosplay = "Cosplay"
    case asianPorn = "Asian Porn"
    case misc = "Misc"

    public var id: String { rawValue }

    /// Parses both the current API spelling and the legacy "... Sets" spelling stored by 3.x.
    public init?(apiName: String) {
        switch apiName.trimmingCharacters(in: .whitespaces).lowercased() {
        case "doujinshi": self = .doujinshi
        case "manga": self = .manga
        case "artist cg", "artist cg sets", "artistcg": self = .artistCG
        case "game cg", "game cg sets", "gamecg": self = .gameCG
        case "western": self = .western
        case "non-h", "non_h", "nonh": self = .nonH
        case "image set", "image sets", "imageset": self = .imageSet
        case "cosplay": self = .cosplay
        case "asian porn", "asianporn": self = .asianPorn
        case "misc", "private": self = .misc
        default: return nil
        }
    }

    /// Bit used by the site's `f_cats` exclusion mask.
    var filterBit: Int {
        switch self {
        case .misc: 1
        case .doujinshi: 2
        case .manga: 4
        case .artistCG: 8
        case .gameCG: 16
        case .imageSet: 32
        case .cosplay: 64
        case .asianPorn: 128
        case .nonH: 256
        case .western: 512
        }
    }

    /// Key used by the 3.x search document (`doujinshi`, `non_h`, ...).
    public var legacyKey: String {
        switch self {
        case .doujinshi: "doujinshi"
        case .manga: "manga"
        case .artistCG: "artistcg"
        case .gameCG: "gamecg"
        case .western: "western"
        case .nonH: "non_h"
        case .imageSet: "imageset"
        case .cosplay: "cosplay"
        case .asianPorn: "asianporn"
        case .misc: "misc"
        }
    }

    /// The colour old users know each category by, as 0...255 RGB.
    public var rgb: (red: Int, green: Int, blue: Int) {
        switch self {
        case .doujinshi: (255, 59, 59)
        case .manga: (255, 186, 59)
        case .artistCG: (234, 220, 59)
        case .gameCG: (59, 157, 59)
        case .western: (164, 255, 76)
        case .nonH: (76, 180, 255)
        case .imageSet: (59, 59, 255)
        case .cosplay: (117, 59, 159)
        case .asianPorn: (243, 176, 243)
        case .misc: (212, 212, 212)
        }
    }
}
