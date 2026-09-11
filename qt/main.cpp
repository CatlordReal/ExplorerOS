#include <QApplication>
#include <QComboBox>
#include <QClipboard>
#include <QFontMetrics>
#include <QRegularExpression>
#include <QStyleHints>
#include <QStyle>
#include <QSignalBlocker>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFrame>
#include <QFormLayout>
#include <QFileInfo>
#include <QGridLayout>
#include <QHash>
#include <QHBoxLayout>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLabel>
#include <QLineEdit>
#include <QMainWindow>
#include <QPainter>
#include <QProcess>
#include <QPushButton>
#include <QSettings>
#include <QStringList>
#include <QStatusBar>
#include <QTimeEdit>
#include <QTimer>
#include <QVBoxLayout>

struct Palette { QColor background, surface, foreground, accent, muted; };

static Palette paletteFor(const QString &theme) {
    const QHash<QString, Palette> palettes {
        {"Latte",        {"#eff1f5", "#ffffff", "#4c4f69", "#1e66f5", "#8c8fa1"}},
        {"Frappé",       {"#303446", "#414559", "#c6d0f5", "#8caaee", "#a5adce"}},
        {"Macchiato",    {"#24273a", "#363a4f", "#cad3f5", "#8aadf4", "#a5adcb"}},
        {"Mocha",        {"#1e1e2e", "#313244", "#cdd6f4", "#89b4fa", "#a6adc8"}},
        {"Sand",         {"#f3ead8", "#fff9ec", "#3d3225", "#a6672d", "#806d56"}},
        {"Dawn Paper",   {"#f9f2e7", "#fffdf8", "#443a30", "#b7673f", "#89786a"}},
        {"Golden Sand",  {"#4a361d", "#604727", "#fff3ce", "#f2b84b", "#dcc28b"}},
        {"Golden Paper", {"#fff4d8", "#fffaf0", "#4c3516", "#bd7a19", "#896c3b"}},
        {"Sunset",       {"#3d2630", "#553542", "#ffe6dc", "#ed8b67", "#d4a39b"}},
        {"Dusk",         {"#202431", "#303747", "#e3e7f1", "#a9b8e9", "#aab3c9"}}
    };
    return palettes.value(theme, palettes.value("Mocha"));
}

class GlassCanvas final : public QWidget {
public:
    explicit GlassCanvas(QWidget *parent = nullptr) : QWidget(parent) { setMinimumSize(640, 360); setMaximumSize(640, 360); }
    void setPalette(const Palette &value) { colors = value; update(); }
    void setCard(const QString &title, const QString &body, const QString &source) { cardTitle = title; cardBody = body; cardSource = source; navigation = false; update(); }
    void setNavigation(const QString &instruction, const QString &distance, const QString &destination, const QString &step, const QString &total) { navInstruction = instruction; navDistance = distance; navDestination = destination; navStep = step; navTotal = total; navigation = true; update(); }
    void clearNavigation() { navInstruction.clear(); navDistance.clear(); navDestination.clear(); navStep.clear(); navTotal.clear(); navigation = false; update(); }
    void clear() { cardTitle.clear(); cardBody.clear(); cardSource.clear(); clearNavigation(); }

protected:
    void paintEvent(QPaintEvent *) override {
        QPainter painter(this); painter.fillRect(rect(), colors.background); painter.setRenderHint(QPainter::Antialiasing);
        painter.setPen(QPen(colors.muted, 2)); painter.drawRoundedRect(rect().adjusted(8, 8, -8, -8), 20, 20);
        painter.setPen(colors.muted); painter.setFont(QFont("Sans Serif", 12)); painter.drawText(28, 38, "Simulated Glass");
        if (navigation) {
            painter.setPen(colors.accent); painter.setFont(QFont("Sans Serif", 42, QFont::DemiBold)); drawWrapped(painter, QRect(30, 72, 580, 116), navInstruction, 2);
            painter.setPen(colors.foreground); painter.setFont(QFont("Sans Serif", 25)); drawWrapped(painter, QRect(30, 202, 580, 78), navDistance + " · " + navDestination, 2);
            painter.setPen(colors.muted); painter.setFont(QFont("Sans Serif", 15)); painter.drawText(30, 325, "Step " + navStep + " of " + navTotal);
        } else if (!cardTitle.isEmpty()) {
            painter.setPen(colors.foreground); painter.setFont(QFont("Sans Serif", 36, QFont::DemiBold)); drawWrapped(painter, QRect(30, 66, 580, 100), cardTitle, 2);
            painter.setFont(QFont("Sans Serif", 22)); drawWrapped(painter, QRect(30, 176, 580, 108), cardBody, 3);
            painter.setPen(colors.muted); painter.setFont(QFont("Sans Serif", 15)); painter.drawText(30, 325, painter.fontMetrics().elidedText(cardSource, Qt::ElideRight, 580));
        } else {
            painter.setPen(colors.foreground); painter.setFont(QFont("Sans Serif", 30)); painter.drawText(QRect(0, 0, width(), height()), Qt::AlignCenter, "Waiting");
        }
    }
private:
    static void drawWrapped(QPainter &painter, const QRect &area, const QString &value, int maxLines) {
        const QFontMetrics metrics = painter.fontMetrics(); const int lines = qMin(maxLines, area.height() / metrics.lineSpacing());
        QString remaining = value.simplified();
        painter.save(); painter.setClipRect(area);
        for (int line = 0; line < lines && !remaining.isEmpty(); ++line) {
            QString shown;
            if (line == lines - 1) { shown = metrics.elidedText(remaining, Qt::ElideRight, area.width()); remaining.clear(); }
            else {
                int end = remaining.size(); while (end > 1 && metrics.horizontalAdvance(remaining.left(end)) > area.width()) --end;
                if (end < remaining.size()) { int space = remaining.lastIndexOf(' ', end); if (space > 0) end = space; }
                shown = remaining.left(end); remaining = remaining.mid(end).trimmed();
            }
            painter.drawText(area.left(), area.top() + metrics.ascent() + line * metrics.lineSpacing(), shown);
        }
        painter.restore();
    }
    Palette colors = paletteFor("Mocha"); bool navigation = false;
    QString cardTitle, cardBody, cardSource, navInstruction, navDistance, navDestination, navStep, navTotal;
};

class Window final : public QMainWindow {
public:
    explicit Window(bool demo = false) : demoMode(demo) {
        auto *root = new QWidget; auto *layout = new QVBoxLayout(root); layout->setContentsMargins(18, 18, 18, 18); layout->setSpacing(12);
        canvas = new GlassCanvas; layout->addWidget(canvas, 0, Qt::AlignHCenter);
        status = new QLabel("Stopped"); layout->addWidget(status);
        auto *pairing = new QHBoxLayout; pairingKey = new QLineEdit; pairingKey->setReadOnly(true); pairingKey->setEchoMode(QLineEdit::Password); pairingKey->setPlaceholderText("Start endpoint for pairing key"); pairingKey->setAccessibleName("Pairing key");
        reveal = new QPushButton("Reveal"); reveal->setCheckable(true); reveal->setEnabled(false); copy = new QPushButton("Copy key"); copy->setEnabled(false);
        pairing->addWidget(pairingKey, 1); pairing->addWidget(reveal); pairing->addWidget(copy); layout->addLayout(pairing);
        connect(reveal, &QPushButton::toggled, this, [this](bool shown) { pairingKey->setEchoMode(shown ? QLineEdit::Normal : QLineEdit::Password); reveal->setText(shown ? "Hide" : "Reveal"); });
        connect(copy, &QPushButton::clicked, this, [this] { if (!pairingKey->text().isEmpty()) { copiedKey = pairingKey->text(); QApplication::clipboard()->setText(copiedKey); } });
        auto *controls = new QGridLayout;
        for (const QString &gesture : {"tap", "doubleTap", "swipeLeft", "swipeRight", "swipeDown", "camera", "cameraLongPress"}) {
            auto *button = new QPushButton(gesture); controls->addWidget(button, controls->count() / 4, controls->count() % 4); connect(button, &QPushButton::clicked, this, [this, gesture] { control(gesture); });
        }
        layout->addLayout(controls);
        auto *form = new QFormLayout;
        theme = new QComboBox; theme->addItems({"Latte", "Frappé", "Macchiato", "Mocha", "Sand", "Dawn Paper", "Golden Sand", "Golden Paper", "Sunset", "Dusk"});
        appearance = new QComboBox; appearance->addItems({"System", "Light", "Dark"});
        schedule = new QComboBox; schedule->addItems({"Manual", "Clock schedule", "Configured phases"});
        sunrise = new QTimeEdit(QTime(6, 30)); golden = new QTimeEdit(QTime(18, 0)); sunset = new QTimeEdit(QTime(19, 15)); dusk = new QTimeEdit(QTime(20, 0));
        form->addRow("Theme", theme); form->addRow("Appearance", appearance); form->addRow("Switching", schedule); form->addRow("Sunrise", sunrise); form->addRow("Golden hour", golden); form->addRow("Sunset", sunset); form->addRow("Dusk", dusk); layout->addLayout(form);
        auto *actions = new QHBoxLayout; start = new QPushButton("Start"); stop = new QPushButton("Stop"); stop->setEnabled(false); auto *card = new QPushButton("Demo card"); auto *route = new QPushButton("Demo route"); actions->addWidget(start); actions->addWidget(stop); actions->addWidget(card); actions->addWidget(route); layout->addLayout(actions);
        setCentralWidget(root); setWindowTitle("Explorer Link Qt Simulator"); resize(690, 820);
        connect(start, &QPushButton::clicked, this, [this] { startSimulator(); }); connect(stop, &QPushButton::clicked, this, [this] { stopSimulator(); });
        connect(card, &QPushButton::clicked, this, [this] { canvas->setCard("Hello", "Synthetic local card", "companion"); control("card Hello|Synthetic local card|companion"); });
        connect(route, &QPushButton::clicked, this, [this] { canvas->setNavigation("Turn left", "120 m", "Demo destination", "1", "3"); control("navigation Turn left|120 m|Demo destination|1|3|demo"); });
        connect(theme, &QComboBox::currentTextChanged, this, [this] { applyTheme(); saveSettings(); }); connect(appearance, &QComboBox::currentTextChanged, this, [this] { applyTheme(); saveSettings(); }); connect(schedule, &QComboBox::currentTextChanged, this, [this] { applyTheme(); saveSettings(); });
        for (auto *time : {sunrise, golden, sunset, dusk}) connect(time, &QTimeEdit::timeChanged, this, [this] { applyTheme(); saveSettings(); });
        timer.setInterval(60 * 1000); connect(&timer, &QTimer::timeout, this, [this] { applyTheme(); }); timer.start();
        connect(&process, &QProcess::readyReadStandardOutput, this, [this] { readEvents(); });
        connect(&process, &QProcess::readyReadStandardError, this, [this] { process.readAllStandardError(); status->setText("Endpoint error"); });
        connect(&process, &QProcess::stateChanged, this, [this](QProcess::ProcessState state) { start->setEnabled(state == QProcess::NotRunning); stop->setEnabled(state != QProcess::NotRunning); });
        connect(&process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) { clearSession(); status->setText(error == QProcess::FailedToStart ? "Python unavailable" : error == QProcess::Crashed ? "Endpoint crashed" : "Endpoint error"); });
        connect(&process, qOverload<int, QProcess::ExitStatus>(&QProcess::finished), this, [this](int code, QProcess::ExitStatus exit) { process.readAllStandardOutput(); process.readAllStandardError(); clearSession(); status->setText(stopping || (exit == QProcess::NormalExit && code == 0) ? "Stopped" : "Endpoint failed"); stopping = false; });
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
        connect(QGuiApplication::styleHints(), &QStyleHints::colorSchemeChanged, this, [this] { applyTheme(); });
#endif
        if (!demoMode) {
        QSettings settings("ExplorerOS", "ExplorerLinkQt");
        { const QSignalBlocker themeBlock(theme), appearanceBlock(appearance), scheduleBlock(schedule), sunriseBlock(sunrise), goldenBlock(golden), sunsetBlock(sunset), duskBlock(dusk);
          theme->setCurrentText(settings.value("theme", "Mocha").toString()); appearance->setCurrentText(settings.value("appearance", "System").toString());
          QString savedSchedule = settings.value("schedule", "Manual").toString(); if (savedSchedule == "Auto solar") savedSchedule = "Configured phases"; else if (savedSchedule == "Auto time") savedSchedule = "Clock schedule"; schedule->setCurrentText(savedSchedule);
          sunrise->setTime(settings.value("sunrise", QTime(6, 30)).toTime()); golden->setTime(settings.value("golden", QTime(18, 0)).toTime()); sunset->setTime(settings.value("sunset", QTime(19, 15)).toTime()); dusk->setTime(settings.value("dusk", QTime(20, 0)).toTime()); }
        } else { theme->setCurrentText("Mocha"); appearance->setCurrentText("Dark"); setWindowTitle("Explorer Link · Synthetic examples"); }
        applyTheme();
    }
    ~Window() override { stopSimulator(); saveSettings(); }
    bool renderExamples(const QString &directory) {
        if (!demoMode || QFileInfo::exists(directory) || !QDir().mkpath(directory)) return false;
        auto event = [this](const QJsonObject &value) {
            const QByteArray bytes = QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n';
            // Exercise the same fragmented-line parser used for Python stdout.
            consumeEvents(bytes.left(7)); consumeEvents(bytes.mid(7));
        };
        auto capture = [this, &directory](const QString &name) {
            QApplication::processEvents();
            return canvas->grab().save(QDir(directory).filePath(name + "-canvas.png"))
                && grab().save(QDir(directory).filePath(name + "-window.png"));
        };
        event({{"event", "status"}, {"connected", true}});
        event({{"event", "card"}, {"title", "New message"}, {"body", "Alex: Meet at the station entrance at 6?"}, {"source", "Synthetic notification example"}});
        if (!capture("notification")) return false;
        event({{"event", "card"}, {"title", "Shopping note"}, {"body", "Coffee, oat milk, bread. Pick up the parcel on the way home."}, {"source", "Synthetic Quick Notes example"}});
        if (!capture("note")) return false;
        event({{"event", "navigation"}, {"instruction", "Turn left"}, {"distance", "120 m"}, {"destination", "Station entrance"}, {"step", "2"}, {"total", "5"}});
        if (!capture("navigation")) return false;
        event({{"event", "status"}, {"connected", false}, {"host", "127.0.0.1"}, {"port", 8765}});
        return capture("disconnected");
    }
private:
    void saveSettings() { if (demoMode) return; QSettings settings("ExplorerOS", "ExplorerLinkQt"); settings.setValue("theme", theme->currentText()); settings.setValue("appearance", appearance->currentText()); settings.setValue("schedule", schedule->currentText()); settings.setValue("sunrise", sunrise->time()); settings.setValue("golden", golden->time()); settings.setValue("sunset", sunset->time()); settings.setValue("dusk", dusk->time()); }
    void clearSession() { canvas->clear(); eventBuffer.fill(0); eventBuffer.clear(); pairingKey->clear(); reveal->setChecked(false); reveal->setEnabled(false); copy->setEnabled(false); if (!copiedKey.isEmpty() && QApplication::clipboard()->text() == copiedKey) QApplication::clipboard()->clear(); copiedKey.fill(QChar(0)); copiedKey.clear(); }
    void startSimulator() {
        if (process.state() != QProcess::NotRunning) return;
        clearSession(); stopping = false;
        const QString root = repositoryRoot();
        const QString bundledPython = QDir(root).filePath(".venv/bin/python");
        process.setWorkingDirectory(root);
        process.setProgram(qEnvironmentVariable("PYTHON", QFileInfo::exists(bundledPython) ? bundledPython : "python3"));
        process.setArguments({"-m", "simulator.server", "--host", "127.0.0.1", "--port", "8765", "--synthetic-ui"});
        process.start(); status->setText("Starting · 127.0.0.1:8765");
    }
    void stopSimulator() { stopping = true; if (process.state() != QProcess::NotRunning) { control("quit"); process.waitForFinished(1500); if (process.state() != QProcess::NotRunning) { process.kill(); process.waitForFinished(1500); } } clearSession(); status->setText("Stopped"); }
    QString repositoryRoot() const {
        const QString explicitRoot = qEnvironmentVariable("EXPLOREROS_ROOT");
        if (!explicitRoot.isEmpty()) return explicitRoot;
        QDir candidate(QCoreApplication::applicationDirPath());
        for (int level = 0; level < 7; ++level) {
            if (candidate.exists("simulator")) return candidate.absolutePath();
            if (!candidate.cdUp()) break;
        }
        return QDir::currentPath();
    }
    void control(const QString &line) { if (process.state() != QProcess::NotRunning) { process.write(line.toUtf8() + "\n"); process.waitForBytesWritten(200); } }
    QString activeTheme() const {
        if (schedule->currentText() == "Manual") return theme->currentText();
        const QTime now = QTime::currentTime();
        if (schedule->currentText() == "Configured phases" && !(sunrise->time() < golden->time() && golden->time() < sunset->time() && sunset->time() < dusk->time())) return theme->currentText();
        if (schedule->currentText() == "Configured phases") { if (now < sunrise->time()) return "Dusk"; if (now < golden->time()) return "Sand"; if (now < sunset->time()) return "Golden Sand"; if (now < dusk->time()) return "Sunset"; return "Dusk"; }
        const int hour = now.hour(); if (hour < 6) return "Dusk"; if (hour < 9) return "Dawn Paper"; if (hour < 17) return "Sand"; if (hour < 19) return "Golden Sand"; if (hour < 21) return "Sunset"; return "Dusk";
    }
    QString appearanceTheme() const {
        const QString selected = activeTheme();
        bool dark = appearance->currentText() == "Dark";
        if (appearance->currentText() == "System") {
#if QT_VERSION >= QT_VERSION_CHECK(6, 5, 0)
            dark = QGuiApplication::styleHints()->colorScheme() == Qt::ColorScheme::Dark;
#else
            dark = qApp->style()->standardPalette().color(QPalette::Window).lightness() < 128;
#endif
        }
        const bool catppuccin = QStringList{"Latte", "Frappé", "Macchiato", "Mocha"}.contains(selected);
        const bool selectedDark = paletteFor(selected).background.lightness() < 128;
        if (selectedDark == dark) return selected;
        return dark ? (catppuccin ? "Mocha" : "Dusk") : (catppuccin ? "Latte" : "Dawn Paper");
    }
    void applyTheme() {
        const bool configured = schedule->currentText() == "Configured phases";
        for (auto *time : {sunrise, golden, sunset, dusk}) time->setEnabled(configured);
        const bool ordered = sunrise->time() < golden->time() && golden->time() < sunset->time() && sunset->time() < dusk->time();
        schedule->setToolTip(configured && !ordered ? "Set phases in ascending time order" : "");
        const Palette colors = paletteFor(appearanceTheme()); canvas->setPalette(colors);
        const QString base = QString("QWidget{background:%1;color:%2;} QLineEdit,QComboBox,QTimeEdit,QPushButton{background:%3;color:%2;border:1px solid %4;border-radius:6px;padding:6px;} QPushButton:hover{border-color:%5;}")
            .arg(colors.background.name(), colors.foreground.name(), colors.surface.name(), colors.muted.name(), colors.accent.name());
        qApp->setStyleSheet(base);
    }
    void readEvents() { consumeEvents(process.readAllStandardOutput()); }
    void consumeEvents(const QByteArray &bytes) {
        eventBuffer += bytes;
        if (eventBuffer.size() > 65536) { process.kill(); clearSession(); status->setText("Endpoint output invalid"); return; }
        for (qsizetype end; (end = eventBuffer.indexOf('\n')) >= 0;) {
            QByteArray line = eventBuffer.left(end).trimmed(); eventBuffer.remove(0, end + 1);
            if (line.startsWith("PAIRING_KEY=")) {
                QString value = QString::fromLatin1(line.mid(12));
                if (QRegularExpression("^[0-9a-fA-F]{64}$").match(value).hasMatch()) { pairingKey->setText(value); reveal->setEnabled(true); copy->setEnabled(true); }
                value.fill(QChar(0)); line.fill(0); continue;
            }
            const QJsonDocument doc = QJsonDocument::fromJson(line); if (!doc.isObject()) continue; const QJsonObject event = doc.object(); const QString type = event.value("event").toString();
            if (type == "status") { const bool connected = event.value("connected").toBool(); status->setText(connected ? "Connected" : QString("Listening · %1:%2").arg(event.value("host").toString("127.0.0.1")).arg(event.value("port").toInt(8765))); if (demoMode) status->setText(status->text() + " · Synthetic example"); if (!connected) canvas->clear(); }
            else if (type == "card" && event.contains("title")) canvas->setCard(event.value("title").toString(), event.value("body").toString(), event.value("source").toString());
            else if (type == "card" && event.contains("active") && !event.value("active").toBool()) canvas->clear();
            else if (type == "navigation" && event.contains("instruction")) canvas->setNavigation(event.value("instruction").toString(), event.value("distance").toString(), event.value("destination").toString(), event.value("step").toString(), event.value("total").toString());
            else if (type == "navigation" && !event.value("active").toBool()) canvas->clearNavigation();
        }
    }
    GlassCanvas *canvas; QLabel *status; QLineEdit *pairingKey; QPushButton *reveal, *copy, *start, *stop; QByteArray eventBuffer; QString copiedKey; bool stopping = false; bool demoMode = false; QComboBox *theme, *appearance, *schedule; QTimeEdit *sunrise, *golden, *sunset, *dusk; QTimer timer; QProcess process;
};

int main(int argc, char *argv[]) {
    bool demo = false;
    for (int index = 1; index < argc; ++index) if (QString::fromLocal8Bit(argv[index]) == "--demo-output") demo = true;
    if (demo) qputenv("QT_QPA_PLATFORM", "offscreen");
    QApplication app(argc, argv);
    const QStringList arguments = app.arguments();
    if (demo && (arguments.size() != 3 || arguments[1] != "--demo-output" || arguments[2].isEmpty())) return 2;
    Window window(demo); window.show();
    if (demo) return window.renderExamples(arguments[2]) ? 0 : 1;
    return app.exec();
}
