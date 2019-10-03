/*
 * Copyright (c) 2016-present Razeware LLC
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * Notwithstanding the foregoing, you may not use, copy, modify, merge, publish,
 * distribute, sublicense, create a derivative work, and/or sell copies of the
 * Software in any work that is designed, intended, or marketed for pedagogical or
 * instructional purposes related to programming, coding, application development,
 * or information technology.  Permission for such use, copying, modification,
 * merger, publication, distribution, sublicensing, creation of derivative works,
 * or sale is expressly withheld.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

import UIKit
import RxSwift
import RxCocoa
import Kingfisher
import RxSwiftExt

func cachedFileURL(_ fileName: String)->URL{
   return FileManager
     .default
     .urls(for: .cachesDirectory, in: .allDomainsMask)[0]
     .appendingPathComponent(fileName)
 }

class ActivityController: UITableViewController {
  private let repo = "ReactiveX/RxSwift"

  private let eventsFileURL = cachedFileURL("events.plist")
  private let modifiedFileURL = cachedFileURL("modified.txt")
  
  private let lastModified = BehaviorRelay<NSString?>(value: nil)
  private let events = BehaviorRelay<[Event]>(value: [])
  private let bag = DisposeBag()

  override func viewDidLoad() {
    super.viewDidLoad()
    title = repo

    self.refreshControl = UIRefreshControl()
    let refreshControl = self.refreshControl!

    refreshControl.backgroundColor = UIColor(white: 0.98, alpha: 1.0)
    refreshControl.tintColor = UIColor.darkGray
    refreshControl.attributedTitle = NSAttributedString(string: "Pull to refresh")
    refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)

    readEventFromSavedData()
    lastModified.accept(try? NSString(contentsOf: modifiedFileURL, usedEncoding: nil))
    refresh()
  }

  @objc func refresh() {
    DispatchQueue.global(qos: .default).async { [weak self] in
      guard let self = self else { return }
      self.fetchEvents(repo: self.repo)
    }
  }

  func fetchEvents(repo: String) {
     let response = Observable.from(
      ["https://api.github.com/search/repositories?q=language:swift&per_page=5"])
      .map{ URL(string: $0)!}
      .map({ URLRequest(url: $0)})
      .flatMap({ URLSession.shared.rx.json(request: $0)})
      .flatMap { (json) -> Observable<String> in
        guard let dict = json as? [String: Any],
              let array = dict["items"] as? [[String: Any]] else{
          return Observable.never()
        }
        return Observable.from(array.map { $0["full_name"] as! String }) }
      .map({ URL(string: "https://api.github.com/repos/\($0)/events?per_page=5")! })
      .map { [weak self] url -> URLRequest in
        var request = URLRequest(url: url)
        if let modifiedHeader = self?.lastModified.value {
          request.addValue(modifiedHeader as String,
            forHTTPHeaderField: "Last-Modified")
        }
        return request }
      .flatMap({ URLSession.shared.rx.response(request: $0)})
      .share(replay: 1)
  
      
//    let response = Observable
//      .from([repo])
//      .map( { URL(string: "https://api.github.com/repos/\($0)/events")!})
//      .map { [weak self] url -> URLRequest in
//        var request = URLRequest(url: url)
//        if let modifiedHeader = self?.lastModified.value {
//          request.addValue(modifiedHeader as String,
//            forHTTPHeaderField: "Last-Modified")
//      }
//        return request
//      }
//      .flatMap({ URLSession.shared.rx.response(request: $0)})
//      .share(replay: 1)
    
    response
      .filter { (response, data) -> Bool in
        return 200..<300 ~= response.statusCode}
      .map({ try? JSONDecoder().decode([Event].self, from: $1) })
      .unwrap()
      .filter({ $0.count > 0})
      .subscribe(onNext: { [weak self](events) in
        print(events.count)
        self?.processEvents(events) })
      .disposed(by: bag)

    response
      .filter { (response, _) -> Bool in
        return 200..<400 ~= response.statusCode}
      .flatMap { (response, _) -> Observable<NSString> in
        guard let value = response.allHeaderFields["Last-Modified"]  as? NSString else {
            return Observable.never() }
        return Observable.just(value) }
      .subscribe(onNext: { [weak self] modifiedHeader in
        guard let strongSelf = self else { return }
        strongSelf.lastModified.accept(modifiedHeader)
        try? modifiedHeader.write(to: strongSelf.modifiedFileURL, atomically: true,
        encoding: String.Encoding.utf8.rawValue) })
      .disposed(by: bag)
  }
  
  func processEvents(_ newEvents: [Event]) {
    var updatedEvents = newEvents + events.value
    if updatedEvents.count > 25{
      updatedEvents = Array<Event>(updatedEvents.prefix(upTo: 25))
    }
    events.accept(updatedEvents)
    DispatchQueue.main.async {
      self.tableView.reloadData()
      self.refreshControl?.endRefreshing()
    }
//    print(eventsFileURL)
    saveDataWith(updatedEvents: updatedEvents)
  }
  
  func readEventFromSavedData(){
    if let xml = try? Data(contentsOf: eventsFileURL),
       let eventArray = try? PropertyListDecoder().decode([Event].self, from: xml){
      events.accept(eventArray)
    }
  }
  
  func saveDataWith(updatedEvents: [Event]){
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .xml

    do {
        let data = try encoder.encode(updatedEvents)
        try data.write(to: eventsFileURL)
    } catch {
        print(error)
    }
  }

  // MARK: - Table Data Source
  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    return events.value.count
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let event = events.value[indexPath.row]

    let cell = tableView.dequeueReusableCell(withIdentifier: "Cell")!
    cell.textLabel?.text = event.actor.name
    cell.detailTextLabel?.text = event.repo.name + ", " + event.action.replacingOccurrences(of: "Event", with: "").lowercased()
    cell.imageView?.kf.setImage(with: event.actor.avatar, placeholder: UIImage(named: "blank-avatar"))
    return cell
  }
}
