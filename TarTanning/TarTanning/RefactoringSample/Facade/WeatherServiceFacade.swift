//
//  WeatherServiceFacade.swift
//  TarTanning
//
//  Created by taeni on 8/12/25.
//

import Combine
import Foundation
import WeatherKit
import CoreLocation

@MainActor
protocol WeatherServiceFacadeProtocol: ObservableObject {
    // 상태 관리
    var isReady: Bool { get }
    var errorMessage: String? { get }
    var currentLocation: LocationInfo? { get }
    
    // 권한 및 초기화
    func requestLocationPermission() async -> Bool
    func checkLocationPermission() async -> Bool
    func initialize() async
    
    // 날씨 데이터 관리
    func refreshCurrentWeather() async throws -> WeatherSummary
    func getCurrentWeather() async -> WeatherSummary?
    func getWeatherForLocation(_ location: LocationInfo) async throws -> WeatherSummary
    func getHourlyForecast(for date: Date) async throws -> [HourlyWeatherData]
    
    // 위치 관리
    func updateLocation(_ location: LocationInfo) async
    func getCurrentLocation() async throws -> LocationInfo
}

struct HourlyWeatherData {
    let hour: Int
    let uvIndex: Double
    let temperature: Double
    let condition: WeatherCondition
}

// MARK: - WeatherServiceFacade Implementation

@MainActor
final class WeatherServiceFacade: ObservableObject, WeatherServiceFacadeProtocol {
    
    // MARK: - Published Properties
    @Published private(set) var isReady: Bool = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentLocation: LocationInfo?
    @Published private(set) var lastUpdateDate: Date?
    
    // MARK: - Private Properties
    private let weatherService = WeatherService.shared
    private let locationManager = CLLocationManager()
    
    // 캐싱
    private var cachedWeatherData: WeatherSummary?
    private var cachedLocation: LocationInfo?
    private var lastCacheUpdate: Date?
    private let cacheValidityDuration: TimeInterval = 600 // 10분
    
    // WeatherKit Manager (기존)
    private let weatherKitManager = WeatherKitManager.shared
    
    // Location Delegate
    private var locationDelegate: LocationManagerDelegate?
    
    // Combine
    private var cancellables = Set<AnyCancellable>()
    private let weatherUpdateSubject = PassthroughSubject<WeatherSummary, Never>()
    
    // MARK: - Initialization
    
    init() {
        setupLocationManager()
        
        Task {
            await initialize()
        }
    }
    
    // MARK: - Public Interface
    
    func requestLocationPermission() async -> Bool {
        return await withCheckedContinuation { continuation in
            let delegate = LocationManagerDelegate { authorized in
                continuation.resume(returning: authorized)
            }
            
            self.locationDelegate = delegate
            locationManager.delegate = delegate
            locationManager.requestWhenInUseAuthorization()
        }
    }
    
    func checkLocationPermission() async -> Bool {
        let status = locationManager.authorizationStatus
        return status == .authorizedWhenInUse || status == .authorizedAlways
    }
    
    func initialize() async {
        let hasLocationPermission = await checkLocationPermission()
        
        if hasLocationPermission {
            do {
                let location = try await getCurrentLocation()
                await updateLocation(location)
                await updateReadyStatus()
                
                // 초기 날씨 데이터 로드
                let _ = try await refreshCurrentWeather()
                
            } catch {
                await MainActor.run {
                    errorMessage = "초기화 실패: \(error.localizedDescription)"
                }
            }
        }
        
        await updateReadyStatus()
    }
    
    func refreshCurrentWeather() async throws -> WeatherSummary {
        guard isReady, let location = currentLocation else {
            throw WeatherServiceError.serviceNotReady
        }
        
        return try await getWeatherForLocation(location)
    }
    
    func getCurrentWeather() async -> WeatherSummary? {
        // 캐시 확인
        if let cached = cachedWeatherData,
           let lastUpdate = lastCacheUpdate,
           Date().timeIntervalSince(lastUpdate) < cacheValidityDuration {
            return cached
        }
        
        // 캐시가 없거나 만료된 경우 비동기로 새로 가져오기
        Task {
            do {
                let _ = try await refreshCurrentWeather()
            } catch {
                print("[WeatherServiceFacade] Background weather refresh failed: \(error)")
            }
        }
        
        return cachedWeatherData
    }
    
    func getWeatherForLocation(_ location: LocationInfo) async throws -> WeatherSummary {
        do {
            errorMessage = nil
            
            // WeatherKit을 통해 날씨 데이터 가져오기
            let weather = try await weatherKitManager.fetchRawWeatherData(for: location)
            let summary = processWeatherData(weather, for: location)
            
            // 캐시 업데이트 (현재 위치인 경우만)
            if location.latitude == currentLocation?.latitude,
               location.longitude == currentLocation?.longitude {
                await MainActor.run {
                    cachedWeatherData = summary
                    lastCacheUpdate = Date()
                    lastUpdateDate = Date()
                }
                
                // 데이터 업데이트 알림
                weatherUpdateSubject.send(summary)
            }
            
            return summary
            
        } catch {
            await MainActor.run {
                errorMessage = "날씨 데이터 조회 실패: \(error.localizedDescription)"
            }
            throw WeatherServiceError.dataFetchFailed(error)
        }
    }
    
    func getHourlyForecast(for date: Date) async throws -> [HourlyWeatherData] {
        guard isReady, let location = currentLocation else {
            throw WeatherServiceError.serviceNotReady
        }
        
        do {
            let weather = try await weatherKitManager.fetchRawWeatherData(for: location)
            
            // 옵셔널 바인딩 제거
            let hourlyForecast = weather.hourlyForecast
            
            let calendar = Calendar.current
            let targetDay = calendar.startOfDay(for: date)
            
            let hourlyData = hourlyForecast.forecast.compactMap { hourlyWeather -> HourlyWeatherData? in
                let hourDate = calendar.startOfDay(for: hourlyWeather.date)
                guard calendar.isDate(hourDate, inSameDayAs: targetDay) else { return nil }
                
                return HourlyWeatherData(
                    hour: calendar.component(.hour, from: hourlyWeather.date),
                    uvIndex: Double(hourlyWeather.uvIndex.value),
                    temperature: hourlyWeather.temperature.value,
                    condition: hourlyWeather.condition
                )
            }
            
            return hourlyData.sorted { $0.hour < $1.hour }
            
        } catch {
            await MainActor.run {
                errorMessage = "시간별 예보 조회 실패: \(error.localizedDescription)"
            }
            throw WeatherServiceError.dataFetchFailed(error)
        }
    }
    
    func updateLocation(_ location: LocationInfo) async {
        await MainActor.run {
            currentLocation = location
            cachedLocation = location
            
            // 위치가 변경되면 캐시 무효화
            cachedWeatherData = nil
            lastCacheUpdate = nil
        }
        
        await updateReadyStatus()
        print("[WeatherServiceFacade] Location updated: \(location.city)")
    }
    
    func getCurrentLocation() async throws -> LocationInfo {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = LocationManagerDelegate { [weak self] authorized in
                guard authorized else {
                    continuation.resume(throwing: WeatherServiceError.locationPermissionDenied)
                    return
                }
                
                self?.locationManager.requestLocation()
            }
            
            delegate.locationUpdate = { location, error in
                if let error = error {
                    continuation.resume(throwing: WeatherServiceError.locationFetchFailed(error))
                } else if let location = location {
                    // 지오코딩으로 도시 이름 가져오기
                    let geocoder = CLGeocoder()
                    geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                        let cityName = placemarks?.first?.locality ?? "Unknown"
                        let locationInfo = LocationInfo(
                            latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude,
                            city: cityName
                        )
                        continuation.resume(returning: locationInfo)
                    }
                } else {
                    continuation.resume(throwing: WeatherServiceError.locationNotAvailable)
                }
            }
            
            self.locationDelegate = delegate
            locationManager.delegate = delegate
            locationManager.requestLocation()
        }
    }
    
    // MARK: - Private Methods
    
    private func setupLocationManager() {
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        locationManager.distanceFilter = 1000 // 1km
    }
    
    private func updateReadyStatus() async {
        let hasLocationPermission = await checkLocationPermission()
        let hasCurrentLocation = currentLocation != nil
        
        await MainActor.run {
            isReady = hasLocationPermission && hasCurrentLocation
        }
    }
    
    private func processWeatherData(_ weather: Weather, for location: LocationInfo) -> WeatherSummary {
        let current = weather.currentWeather
        
        return WeatherSummary(
            temperature: current.temperature.value,
            uvIndex: Double(current.uvIndex.value),
            cityName: location.city,
            condition: current.condition,
            symbolName: current.symbolName,
            humidity: current.humidity,
            windSpeed: current.wind.speed.value,
            timestamp: current.date
        )
    }
}

private class LocationManagerDelegate: NSObject, CLLocationManagerDelegate {
    private let authorizationCompletion: (Bool) -> Void
    var locationUpdate: ((CLLocation?, Error?) -> Void)?
    
    init(authorizationCompletion: @escaping (Bool) -> Void) {
        self.authorizationCompletion = authorizationCompletion
        super.init()
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorized = manager.authorizationStatus == .authorizedWhenInUse ||
                        manager.authorizationStatus == .authorizedAlways
        authorizationCompletion(authorized)
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locationUpdate?(locations.first, nil)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationUpdate?(nil, error)
    }
}

extension WeatherServiceFacade {
    /// 날씨 데이터 업데이트 스트림
    var weatherUpdatePublisher: AnyPublisher<WeatherSummary, Never> {
        weatherUpdateSubject.eraseToAnyPublisher()
    }
}

// MARK: - Helper Extensions
extension WeatherServiceFacade {
    /// UV 인덱스로 특정 시간의 데이터 가져오기
    func getUVIndex(for hour: Int, date: Date = Date()) async throws -> Double {
        let hourlyData = try await getHourlyForecast(for: date)
        return hourlyData.first { $0.hour == hour }?.uvIndex ?? 0.0
    }
    
    /// 디버깅용 상태 로깅
    func logCurrentStatus() {
        print("=== WeatherServiceFacade Status ===")
        print("Ready: \(isReady)")
        print("Current Location: \(currentLocation?.city ?? "None")")
        print("Last Update: \(lastUpdateDate?.formatted() ?? "Never")")
        print("Cached Data: \(cachedWeatherData != nil ? "Available" : "None")")
        print("Error: \(errorMessage ?? "None")")
        print("===================================")
    }
}
