//
//  WeatherDebugViewModel.swift
//  TarTanning
//
//  Created by taeni on 8/12/25.
//

import SwiftUI
import Combine
import CoreLocation

@MainActor
final class WeatherDebugViewModel: ObservableObject {
    @Published var weatherSummary: WeatherSummary?
    @Published var errorMessage: String?
    @Published var isLoading: Bool = false
    
    private let weatherFacade: WeatherServiceFacade
    
    init(weatherFacade: WeatherServiceFacade) {
        self.weatherFacade = weatherFacade
    }
    
    func loadWeather() async {
        isLoading = true
        errorMessage = nil
        
        do {
            // 위치 권한 확인
            let hasPermission = await weatherFacade.checkLocationPermission()
            
            var location: LocationInfo
            
            if hasPermission {
                do {
                    location = try await weatherFacade.getCurrentLocation()
                } catch {
                    // 위치 못 가져오면 포항 기본값으로 대체
                    location = LocationInfo(latitude: 36.0190, longitude: 129.3435, city: "포항")
                }
            } else {
                // 권한 없으면 포항 기본값
                location = LocationInfo(latitude: 36.0190, longitude: 129.3435, city: "포항")
            }
            
            await weatherFacade.updateLocation(location)
            
            // 날씨 데이터 갱신
            let weather = try await weatherFacade.getWeatherForLocation(location)
            
            self.weatherSummary = weather
            
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
}
