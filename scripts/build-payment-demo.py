#!/usr/bin/env python3
"""Build isolated native account/payment UI; requires the backend payment-demo.ts on port19439. No real charge."""
from pathlib import Path
import plistlib
root=Path(__file__).resolve().parents[1]
files=['Diduny/Core/Services/AuthService.swift','Diduny/Core/Storage/KeychainManager.swift','Diduny/Core/Services/BillingService.swift','Diduny/Core/Services/UsageService.swift','Diduny/Features/Settings/AccountSignInView.swift','Diduny/Features/Settings/BillingSettingsSection.swift']
source='import Observation\nimport SwiftUI\nimport os\n'+ '\n'.join((root/f).read_text() for f in files)
settings=(root/'Diduny/Core/Storage/SettingsStorage.swift').read_text()
source += settings[settings.index('enum AppLanguage:'):settings.index('enum HistoryRetentionPolicy:')]
general=(root/'Diduny/Features/Settings/GeneralSettingsView.swift').read_text()
source += general[general.index('struct AppLanguageSettingsSection:'):]
source+='''
enum KeychainError: Error { case saveFailed, accessDenied }

@MainActor final class SettingsStorage { static let shared = SettingsStorage(); var proxyBaseURL = "http://127.0.0.1:19439" }
enum Log { static let app = Logger(subsystem: "diduny.payment.dev", category: "demo") }
enum HTTPLogger {
 static func attachRequestId(_ request: inout URLRequest) -> String { UUID().uuidString }
 static func logRequest(_ request: URLRequest, requestId: String) {}
 static func logResponse(data: Data, response: HTTPURLResponse, requestId: String, startTime: ContinuousClock.Instant) {}
}
struct DemoRoot: View {
 private var auth: AuthService { .shared }
 var body: some View {
   VStack(spacing:0) {
     VStack(alignment:.leading,spacing:8) {
       Text("Diduny · Payment DEV").font(.title2.bold())
       Text("Real sign-in and billing backend · Simulated payment · No real charges").font(.caption).foregroundStyle(.secondary)
       Link("Open local test inbox and instructions",destination:URL(string:"http://127.0.0.1:19439/")!)
     }.frame(maxWidth:.infinity,alignment:.leading).padding(20)
     Divider()
     Form {
       AppLanguageSettingsSection()
       Section("Sign in") { AccountSignInView() }
       if auth.isLoggedIn { AnalyticsSettingsSection() }
       BillingSettingsSection(isLoggedIn:auth.isLoggedIn)
     }.formStyle(.grouped)
   }.frame(width:760,height:780)
   .task(id:auth.userEmail) { if auth.isLoggedIn { await AnalyticsService.shared.refresh() } else { AnalyticsService.shared.reset() } }
 }
}
@main struct DemoApp: App {
 var body:some Scene { WindowGroup("Diduny Payment DEV") { DemoRoot() } }
}
'''
Path('/tmp/DidunyPaymentDemo.swift').write_text(source)
app=Path('/tmp/Diduny Payment Localized DEV.app/Contents');(app/'MacOS').mkdir(parents=True,exist_ok=True)
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'DidunyPaymentDemo','CFBundleIdentifier':'ua.com.rmarinsky.diduny.paymentdemo.localized','CFBundleName':'Diduny Payment Localized DEV','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','uk'],'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}}))

import shutil
for language in ['en','uk']:
    target=app/'Resources'/f'{language}.lproj'
    target.mkdir(parents=True,exist_ok=True)
    shutil.copy2(root/'Diduny/Resources'/f'{language}.lproj'/'Localizable.strings',target/'Localizable.strings')

import subprocess
subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-target','arm64-apple-macos14.0', '/tmp/DidunyPaymentDemo.swift','-o',str(app/'MacOS'/'DidunyPaymentDemo')],check=True)
print('Built /tmp/Diduny Payment Localized DEV.app. Open it manually; payment is simulated.')
