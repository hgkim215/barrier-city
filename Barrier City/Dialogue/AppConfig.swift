//
//  AppConfig.swift
//  WheelchairXR
//
//  Created by mac on 6/22/26.
//

import Foundation
import DialogueKit
import DialogueKitOpenAI

enum AppConfig {
  // 배포한 Worker 주소 (키 아님 — URL만)
  static let proxy = ProxyConfig(base: URL(string: "https://barrier-city-openai-proxy.roiyeon.workers.dev")!)
}
