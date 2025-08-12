//
//  WeatherSummary.swift
//  TarTanning
//
//  Created by taeni on 8/12/25.
//

import WeatherKit
import Foundation

// TODO: DTO라는 명칭이 맞을 지 모르겠으나, 정확히 Weather 에서 가져오는 데이터를 받을 수 있는 struct 가 필요해서 추가하였음
// 위치 정보는 LocationInfo 를 그대로 씀

struct WeatherSummary {
    let temperature: Double
    let uvIndex: Double
    let cityName: String
    let condition: WeatherCondition
    let symbolName: String
    let humidity: Double
    let windSpeed: Double
    let timestamp: Date
    
    var formattedTemperature: String {
        String(format: "%.0f°", temperature)
    }
    
    var uvIndexCategory: String {
        switch Int(uvIndex) {
        case 0...2: return "낮음"
        case 3...5: return "보통"
        case 6...7: return "높음"
        case 8...10: return "매우 높음"
        default: return "위험"
        }
    }
}
