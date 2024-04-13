//
//  webImageAuditApp.swift
//  webImageAudit
//
//  Created by Matthew Stevens on 4/12/24.
//

import SwiftUI
import Combine
import Foundation

struct ContentView: View {
    @State private var productionURL: String = ""
    @State private var testURL: String = ""
    @State private var results: [String] = []  // Store differences as a list of strings
    @State private var isLoading: Bool = false  // Track loading state

    var body: some View {
        VStack{
            Form {
                TextField("Enter Production URL:", text: $productionURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                TextField("Enter Test URL:", text: $testURL)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding()
                Button("Compare", action: performComparison)
                    .disabled(isLoading)
                    .padding()
                
                HStack(spacing: 20) {
                    if isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(width: isLoading ? 30 : 0) // Control width based on loading state
                            .opacity(isLoading ? 1 : 0) // Control visibility
                            .transition(.scale)
                    }
                    
                    if !isLoading { // Only show the list and buttons if not loading
                        List(results, id: \.self) { result in
                            HStack {
                                Text(result)
                                Spacer()
                                Button(action: {
                                    copyTextToClipboard(text: result)
                                }) {
                                    Image(systemName: "doc.on.doc")
                                }
                                .buttonStyle(BorderlessButtonStyle())
                                .padding(.trailing, 8)
                            }
                        }
                        .frame(minWidth: 200)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) // Ensure VStack fills available space and aligns to the top
                Spacer() // Pushes all content to the top
    }
        
        func performComparison() {
            isLoading = true
            results = []  // Optionally clear results when starting a new comparison
            compareImages(productionUrl: productionURL, testUrl: testURL) { differences in
                DispatchQueue.main.async {
                    self.results = differences
                    self.isLoading = false
                }
            }
        }

        private func copyTextToClipboard(text: String) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }


// This struct is for the overall response that includes the session details
struct WebDriverSessionResponse: Decodable {
    let value: WebDriverSession
}

// This struct holds the session-specific data
struct WebDriverSession: Decodable {
    let sessionId: String?
    let capabilities: WebDriverCapabilities
}

// This struct represents the capabilities returned by WebDriver
struct WebDriverCapabilities: Decodable {
    let browserName: String
    let platform: String? // Make optional if platform might not always be present
}


struct ImageComparison: Decodable {
    let imageUrl: URL
    let fileSize: Int

    enum CodingKeys: String, CodingKey {
        case imageUrl = "url"
        case fileSize
    }
}
struct ImageResponse: Decodable {
    let images: [ImageComparison]

    private enum CodingKeys: String, CodingKey {
        case value
    }

    private enum ValueKeys: String, CodingKey {
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let valueContainer = try container.nestedContainer(keyedBy: ValueKeys.self, forKey: .value)
        images = try valueContainer.decode([ImageComparison].self, forKey: .images)
    }
}


func compareImages(productionUrl: String, testUrl: String, completion: @escaping ([String]) -> Void) {
    var sessionId: String = ""
    startSeleniumSession { id in
        guard let id = id else { return }
        sessionId = id
        navigateAndExtractImages(sessionId: sessionId, url: productionUrl) { images1 in
            navigateAndExtractImages(sessionId: sessionId, url: testUrl) { images2 in
                let differences = compareImageSets(set1: images1, set2: images2)
                DispatchQueue.main.async {
                    completion(differences)  // Ensure UI updates on the main thread
                }
                endSeleniumSession(sessionId: sessionId)
            }
        }
    }
}
func navigateAndExtractImages(sessionId: String, url: String, completion: @escaping ([ImageComparison]) -> Void) {
    // Ensure URL is properly formatted and encoded if necessary
    guard let urlEscaped = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
          let scriptUrl = URL(string: "https://webimageaudit.mts-studios.com:4444/wd/hub/session/\(sessionId)/url") else {
        print("Invalid URL")
        completion([])
        return
    }

    // Create request to navigate to the URL
    var navigateRequest = URLRequest(url: scriptUrl)
    navigateRequest.httpMethod = "POST"
    navigateRequest.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    let navigateBody: [String: Any] = ["url": urlEscaped]
    navigateRequest.httpBody = try? JSONSerialization.data(withJSONObject: navigateBody)

    // Execute the navigation request
    URLSession.shared.dataTask(with: navigateRequest) { data, response, error in
        if let error = error {
            print("Error navigating to URL: \(error.localizedDescription)")
            completion([])
            return
        }
        guard let data = data, let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            print("Failed to navigate to URL")
            completion([])
            return
        }

        // Proceed to execute script to extract images
        executeImageExtractionScript(sessionId: sessionId, completion: completion)
    }.resume()
}

func executeImageExtractionScript(sessionId: String, completion: @escaping ([ImageComparison]) -> Void) {
    let scriptUrl = URL(string: "https://webimageaudit.mts-studios.com:4444/wd/hub/session/\(sessionId)/execute/async")!
    var scriptRequest = URLRequest(url: scriptUrl)
    scriptRequest.httpMethod = "POST"
    scriptRequest.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
    
    let script = """
    var callback = arguments[arguments.length - 1];
    setTimeout(() => {
        var allImages = Array.from(document.getElementsByTagName('img'));
                var filteredImages = allImages.filter(img => {
                    let parent = img.parentElement;
                    while (parent) {
                        if (parent.tagName.toLowerCase() === 'header' || parent.tagName.toLowerCase() === 'footer') {
                            return false; // Exclude images inside header or footer
                        }
                        parent = parent.parentElement; // Move up in the DOM tree
                    }
                    if(img.src.includes('bing') || img.src.includes('cookie')){
                        return false;
                    }
                    return true; // Include image if not inside header or footer
                });

                var result = filteredImages.map(img => ({
                    url: img.src,
                    fileSize: img.naturalWidth * img.naturalHeight // Assuming fileSize based on dimensions
                }));
        callback({images: result});
    }, 5000);
    """
    
    let scriptData: [String: Any] = [
        "script": script,
        "args": []
    ]
    scriptRequest.httpBody = try? JSONSerialization.data(withJSONObject: scriptData)

    URLSession.shared.dataTask(with: scriptRequest) { data, response, error in
        if let error = error {
            print("Error executing script: \(error.localizedDescription)")
            completion([])
            return
        }
        guard let data = data else {
            print("No data received or data is nil")
            completion([])
            return
        }
        
        do {
            let jsonImages = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            print(jsonImages)
            let imageDetails = try JSONDecoder().decode(ImageResponse.self, from: data)
            completion(imageDetails.images)
        } catch {
            print("Error decoding image data: \(error)")
            completion([])
        }
    }.resume()
}






func compareImageSets(set1: [ImageComparison], set2: [ImageComparison]) -> [String] {
    var differences: [String] = []

    // Group images by URL
    let set1Grouped = Dictionary(grouping: set1) { extractPathAfterCom(from: $0.imageUrl.absoluteString) }
    let set2Grouped = Dictionary(grouping: set2) { extractPathAfterCom(from: $0.imageUrl.absoluteString) }

    // Check for images present only in set2
    for (urlPath, images2) in set2Grouped {
        if set1Grouped[urlPath] == nil {
            differences.append("\(urlPath)")
        }
    }

    return differences
}


func extractPathAfterCom(from urlString: String) -> String {
    // Search for ".com" in the URL
    guard let range = urlString.range(of: ".com") else { return urlString }
    
    // Include the slash after ".com" in the substring
    let substring = urlString[range.upperBound...]  // Starts immediately after ".com"
    
    // Return the substring, trimming only leading and trailing whitespace characters
    return String(substring).trimmingCharacters(in: .whitespacesAndNewlines)
}


func startSeleniumSession(completion: @escaping (String?) -> Void) {
    let url = URL(string: "https://webimageaudit.mts-studios.com:4444/wd/hub/session")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.addValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

    let postData: [String: Any] = [
        "capabilities": [
            "alwaysMatch": [
                "browserName": "chrome",
                "goog:chromeOptions": [
                    "args": ["--headless","--disable-gpu"]
                ]
            ],
            "timeouts": ["script": 60000]  // Increase script timeout to 60000 milliseconds (60 seconds)
        ]
    ]
    request.httpBody = try? JSONSerialization.data(withJSONObject: postData)

    URLSession.shared.dataTask(with: request) { data, response, error in
        if let error = error {
            print("Error starting session: \(error.localizedDescription)")
            completion(nil)  // Pass nil to indicate error or no session
            return
        }
        guard let data = data else {
            print("No data received.")
            completion(nil)
            return
        }

        do {
            let response = try JSONDecoder().decode(WebDriverSessionResponse.self, from: data)
            completion(response.value.sessionId)  // Directly pass the optional sessionId
        } catch {
            print("Error decoding session response: \(error)")
            completion(nil)
        }
    }.resume()
}




func endSeleniumSession(sessionId: String) {
    let url = URL(string: "https://webimageaudit.mts-studios.com:4444/wd/hub/session/\(sessionId)")!
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"
    URLSession.shared.dataTask(with: request).resume()
}

@main
struct MainApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
            .frame(minWidth: 800, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        }
    }
}
