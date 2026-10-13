import UIKit
import WebKit

// MARK: - 抽出結果（extractor.js の返す JSON）

struct SnapImage: Decodable {
    let url: String
    let kind: String?
    let conf: String      // "high" = 商品本体 / "review" = 要確認
    let reason: String?
    let w: Double?
    let h: Double?
}

struct SnapResult: Decodable {
    let title: String
    let pageUrl: String
    let images: [SnapImage]
    let excludedCount: Int
    let related: Bool?
    let totalImgTags: Int
}

// MARK: - サムネイルセル

final class ThumbCell: UICollectionViewCell {
    static let reuseId = "ThumbCell"
    let imageView = UIImageView()
    let caption = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = UIColor.secondarySystemBackground
        imageView.translatesAutoresizingMaskIntoConstraints = false
        caption.font = UIFont.systemFont(ofSize: 10)
        caption.textAlignment = .center
        caption.numberOfLines = 2
        caption.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)
        contentView.addSubview(caption)
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.heightAnchor.constraint(equalTo: contentView.widthAnchor),
            caption.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 2),
            caption.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - 簡易ブラウザ本体

final class BrowserViewController: UIViewController,
    WKNavigationDelegate, WKUIDelegate, UITextFieldDelegate, UICollectionViewDataSource {

    static let sampleURL = "https://share.shopping.tokyodisneyresort.jp/landing/landing.html?start=3&prod_cd=115001501"
    static let safariUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private var webView: WKWebView!
    private let urlField = UITextField()
    private let uaButton = UIButton(type: .system)
    private let statusLabel = UILabel()
    private var collection: UICollectionView!
    private var collectionHeight: NSLayoutConstraint!
    private let toolbar = UIToolbar()
    private var backItem: UIBarButtonItem!
    private var forwardItem: UIBarButtonItem!

    private var observers: [NSKeyValueObservation] = []
    private var useSafariUA = false

    private var items: [SnapImage] = []
    private var imageCache: [String: UIImage] = [:]
    private var failedURLs = Set<String>()
    private var generation = 0
    private var okCount = 0
    private var ngCount = 0
    private var statusHead = ""
    private var currentPageURL = ""

    private lazy var extractorSource: String? = {
        guard let path = Bundle.main.path(forResource: "extractor", ofType: "js") else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }()

    // MARK: ライフサイクル

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.systemBackground
        buildUI()
        urlField.text = BrowserViewController.sampleURL
        load(text: BrowserViewController.sampleURL)
    }

    private func buildUI() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false

        urlField.borderStyle = .roundedRect
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        urlField.returnKeyType = .go
        urlField.clearButtonMode = .whileEditing
        urlField.font = UIFont.systemFont(ofSize: 13)
        urlField.delegate = self

        uaButton.setTitle("UA:標準", for: .normal)
        uaButton.titleLabel?.font = UIFont.systemFont(ofSize: 13)
        uaButton.addTarget(self, action: #selector(toggleUA), for: .touchUpInside)
        uaButton.setContentHuggingPriority(.required, for: .horizontal)

        let topStack = UIStackView(arrangedSubviews: [urlField, uaButton])
        topStack.axis = .horizontal
        topStack.spacing = 8
        topStack.alignment = .center
        topStack.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = UIFont.systemFont(ofSize: 12)
        statusLabel.numberOfLines = 4
        statusLabel.text = "ページを表示して「画像取得」を押してください"
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = CGSize(width: 96, height: 126)
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collection.backgroundColor = UIColor.systemBackground
        collection.dataSource = self
        collection.register(ThumbCell.self, forCellWithReuseIdentifier: ThumbCell.reuseId)
        collection.translatesAutoresizingMaskIntoConstraints = false

        backItem = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain,
                                   target: self, action: #selector(goBack))
        forwardItem = UIBarButtonItem(image: UIImage(systemName: "chevron.right"), style: .plain,
                                      target: self, action: #selector(goForward))
        let reload = UIBarButtonItem(barButtonSystemItem: .refresh, target: self, action: #selector(reloadPage))
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let grab = UIBarButtonItem(title: "画像取得", style: .done, target: self, action: #selector(extractTapped))
        toolbar.setItems([backItem, forwardItem, reload, flex, grab], animated: false)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(topStack)
        view.addSubview(webView)
        view.addSubview(statusLabel)
        view.addSubview(collection)
        view.addSubview(toolbar)

        let safe = view.safeAreaLayoutGuide
        collectionHeight = collection.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            topStack.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            topStack.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            topStack.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),

            webView.topAnchor.constraint(equalTo: topStack.bottomAnchor, constant: 6),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -4),

            statusLabel.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -8),
            statusLabel.bottomAnchor.constraint(equalTo: collection.topAnchor, constant: -4),

            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            collectionHeight,

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: safe.bottomAnchor)
        ])

        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            guard let self = self else { return }
            if !self.urlField.isFirstResponder, let u = wv.url?.absoluteString {
                self.urlField.text = u
            }
        })
        observers.append(webView.observe(\.canGoBack, options: [.new, .initial]) { [weak self] wv, _ in
            self?.backItem.isEnabled = wv.canGoBack
        })
        observers.append(webView.observe(\.canGoForward, options: [.new, .initial]) { [weak self] wv, _ in
            self?.forwardItem.isEnabled = wv.canGoForward
        })
    }

    // MARK: ナビゲーション

    private func load(text: String) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return }
        if !t.lowercased().hasPrefix("http") { t = "https://" + t }
        guard let url = URL(string: t) else {
            setStatus("URLが不正です: \(t)")
            return
        }
        setStatus("読み込み中… \(t)")
        webView.load(URLRequest(url: url))
    }

    @objc private func goBack() { webView.goBack() }
    @objc private func goForward() { webView.goForward() }
    @objc private func reloadPage() { webView.reload() }

    @objc private func toggleUA() {
        useSafariUA.toggle()
        webView.customUserAgent = useSafariUA ? BrowserViewController.safariUA : nil
        uaButton.setTitle(useSafariUA ? "UA:Safari風" : "UA:標準", for: .normal)
        webView.reload()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        load(text: textField.text ?? "")
        return true
    }

    private func setStatus(_ s: String) {
        statusLabel.text = s
    }

    // MARK: WKNavigationDelegate / WKUIDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(),
           !["http", "https", "about", "blob", "data"].contains(scheme) {
            setStatus("外部アプリ起動などをブロックしました: \(url.absoluteString)")
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setStatus("表示完了: \(webView.title ?? "")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        setStatus("表示失敗: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        setStatus("読み込み失敗: \(error.localizedDescription)")
    }

    // target=_blank のリンクは同じ画面で開く
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: 画像取得

    @objc private func extractTapped() {
        guard let src = extractorSource else {
            setStatus("extractor.js が見つかりません（アプリに同梱されていません）")
            return
        }
        let started = Date()
        generation += 1
        let gen = generation
        setStatus("抽出中…")

        let js = "(function(){\n" + src + "\n" +
            "var r = window.SnapStockerExtract(document, {pageUrl: location.href});\n" +
            "return JSON.stringify({title: r.title, pageUrl: r.pageUrl, images: r.images, " +
            "excludedCount: r.excluded.length, related: !!r.relatedHeadingFound, " +
            "totalImgTags: document.images.length});\n})();"

        webView.evaluateJavaScript(js) { [weak self] result, error in
            guard let self = self, gen == self.generation else { return }
            if let error = error {
                self.setStatus("抽出に失敗（JS実行エラー）: \(error.localizedDescription)")
                return
            }
            guard let text = result as? String, let data = text.data(using: .utf8) else {
                self.setStatus("抽出結果が空でした")
                return
            }
            do {
                let r = try JSONDecoder().decode(SnapResult.self, from: data)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                self.showResult(r, ms: ms, gen: gen)
            } catch {
                self.setStatus("抽出結果の解析に失敗: \(error.localizedDescription)")
            }
        }
    }

    private func showResult(_ r: SnapResult, ms: Int, gen: Int) {
        items = r.images
        imageCache.removeAll()
        failedURLs.removeAll()
        okCount = 0
        ngCount = 0
        currentPageURL = r.pageUrl
        let high = r.images.filter { $0.conf == "high" }.count
        let review = r.images.count - high
        statusHead = "\(r.images.count)枚取得（本体 \(high) / 要確認 \(review)）・除外 \(r.excludedCount)・" +
            "ページ内img \(r.totalImgTags)・関連見出し\(r.related == true ? "あり" : "なし")・抽出 \(ms)ms\n" +
            r.title
        setStatus(statusHead)
        collectionHeight.constant = r.images.isEmpty ? 0 : 130
        collection.reloadData()
        if r.images.isEmpty { return }
        for (idx, item) in r.images.enumerated() {
            fetchThumb(item, index: idx, gen: gen)
        }
    }

    private func fetchThumb(_ item: SnapImage, index: Int, gen: Int) {
        guard let url = URL(string: item.url) else {
            finishThumb(index: index, gen: gen, image: nil, url: item.url)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(currentPageURL, forHTTPHeaderField: "Referer")
        req.setValue(BrowserViewController.safariUA, forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            var img: UIImage? = nil
            if let http = response as? HTTPURLResponse, http.statusCode == 200, let d = data {
                img = UIImage(data: d)
            }
            DispatchQueue.main.async {
                self?.finishThumb(index: index, gen: gen, image: img, url: item.url)
            }
        }.resume()
    }

    private func finishThumb(index: Int, gen: Int, image: UIImage?, url: String) {
        guard gen == generation else { return }
        if let image = image {
            imageCache[url] = image
            okCount += 1
        } else {
            failedURLs.insert(url)
            ngCount += 1
        }
        if index < items.count {
            collection.reloadItems(at: [IndexPath(item: index, section: 0)])
        }
        if okCount + ngCount == items.count {
            setStatus(statusHead + "\nサムネ読込 成功 \(okCount) / 失敗 \(ngCount)")
        }
    }

    // MARK: UICollectionViewDataSource

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return items.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThumbCell.reuseId,
                                                      for: indexPath) as! ThumbCell
        let item = items[indexPath.item]
        let isHigh = item.conf == "high"
        let label = isHigh ? "本体" : "要確認"
        cell.contentView.layer.borderWidth = 2
        cell.contentView.layer.borderColor = (isHigh ? UIColor.systemGreen : UIColor.systemOrange).cgColor
        if let img = imageCache[item.url] {
            cell.imageView.image = img
            cell.caption.text = "\(label) \(Int(img.size.width))×\(Int(img.size.height))"
        } else if failedURLs.contains(item.url) {
            cell.imageView.image = nil
            cell.caption.text = "\(label) 取得失敗"
        } else {
            cell.imageView.image = nil
            cell.caption.text = "\(label) 読込中…"
        }
        return cell
    }
}
