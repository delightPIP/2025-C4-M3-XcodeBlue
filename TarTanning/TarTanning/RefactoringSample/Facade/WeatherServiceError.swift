//
//  WeatherServiceError.swift
//  TarTanning
//
//  Created by taeni on 8/12/25.
//

import Foundation

enum WeatherServiceError: LocalizedError {
    case serviceNotReady
    case locationPermissionDenied
    case locationNotAvailable
    case locationFetchFailed(Error)
    case dataFetchFailed(Error)
    
    var errorDescription: String? {
        switch self {
        case .serviceNotReady:
            return "WeatherService가 준비되지 않았습니다"
        case .locationPermissionDenied:
            return "위치 권한이 거부되었습니다"
        case .locationNotAvailable:
            return "위치 정보를 사용할 수 없습니다"
        case .locationFetchFailed(let error):
            return "위치 조회 실패: \(error.localizedDescription)"
        case .dataFetchFailed(let error):
            return "날씨 데이터 조회 실패: \(error.localizedDescription)"
        }
    }
}
