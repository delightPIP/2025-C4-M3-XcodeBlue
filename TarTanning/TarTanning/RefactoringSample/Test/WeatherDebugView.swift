//
//  WeatherDebugView.swift
//  TarTanning
//
//  Created by taeni on 8/12/25.
//

import SwiftUI

struct WeatherDebugView: View {
    @StateObject private var viewModel: WeatherDebugViewModel
    
    init(weatherFacade: WeatherServiceFacade) {
        _viewModel = StateObject(wrappedValue: WeatherDebugViewModel(weatherFacade: weatherFacade))
    }
    
    var body: some View {
        VStack(spacing: 20) {
            if viewModel.isLoading {
                ProgressView("날씨 정보를 불러오는 중...")
            } else if let error = viewModel.errorMessage {
                Text("에러: \(error)")
                    .foregroundColor(.red)
            } else if let weather = viewModel.weatherSummary {
                VStack(spacing: 10) {
                    Text(weather.cityName)
                        .font(.largeTitle)
                        .bold()
                    
                    Text(weather.formattedTemperature)
                        .font(.system(size: 60))
                    
                    Text("상태: \(weather.condition.description)")
                    Text("습도: \(Int(weather.humidity * 100))%")
                    Text("바람: \(String(format: "%.1f", weather.windSpeed)) m/s")
                    Text("UV 지수: \(weather.uvIndexCategory) (\(Int(weather.uvIndex)))")
                    Text("업데이트: \(weather.timestamp.formatted(date: .abbreviated, time: .shortened))")
                }
            } else {
                Text("날씨 정보를 불러오지 못했습니다.")
            }
            
            Spacer()
            
            Button("날씨 새로고침") {
                Task {
                    await viewModel.loadWeather()
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .task {
            await viewModel.loadWeather()
        }
    }
}

struct ContentViewWrapper: View {
    @State private var weatherFacade: WeatherServiceFacade?

    var body: some View {
        Group {
            if let facade = weatherFacade {
                WeatherDebugView(weatherFacade: facade)
            } else {
                ProgressView("서비스 초기화 중...")
                    .progressViewStyle(CircularProgressViewStyle())
            }
        }
        .task {
            // 메인 액터에서 WeatherServiceFacade 인스턴스 생성
            let facade = await MainActor.run {
                WeatherServiceFacade()
            }
            weatherFacade = facade
        }
    }
}
