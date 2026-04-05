#!/usr/bin/env bash
set -euo pipefail

PORT="${1:-18472}"
APP_DIR="${HOME}/prolog_multimedia_browser_internal"
BACKEND_PL="${APP_DIR}/browser_backend.pl"
FRONTEND_PY="${APP_DIR}/browser_frontend.py"
BACKEND_LOG="${APP_DIR}/backend.log"
SYSTEM_PYTHON="/usr/bin/python3"
BACKEND_PID=""

log() {
  printf '\n==> %s\n' "$*"
}

die() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

cleanup() {
  if [ -n "${BACKEND_PID}" ] && kill -0 "${BACKEND_PID}" >/dev/null 2>&1; then
    kill "${BACKEND_PID}" >/dev/null 2>&1 || true
    wait "${BACKEND_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

validate_port() {
  case "$1" in
    ''|*[!0-9]*) die "Port must be numeric" ;;
  esac
  if [ "$1" -lt 1024 ] || [ "$1" -gt 65535 ]; then
    die "Port must be between 1024 and 65535"
  fi
}

validate_port "${PORT}"

require_cmd bash
require_cmd sudo
require_cmd apt-get
require_cmd swipl
[ -x "${SYSTEM_PYTHON}" ] || die "System Python not found at ${SYSTEM_PYTHON}"

log "Installing dependencies"
if ! sudo apt-get update; then
  printf 'Warning: apt-get update reported problems. Continuing because required packages may still be available from Ubuntu repositories.\n' >&2
fi
sudo apt-get install -y \
  swi-prolog \
  python3 \
  python3-pyqt5 \
  python3-pyqt5.qtwebchannel \
  python3-pyqt5.qtwebengine \
  xdg-utils

log "Checking system Python Qt imports"
env -u PYTHONHOME -u PYTHONPATH "${SYSTEM_PYTHON}" - <<'PYCHECK'
import sys
print('Interpreter :', sys.executable)
print('Version     :', sys.version.split()[0])
from PyQt5.QtCore import QT_VERSION_STR
from PyQt5.QtWebEngineWidgets import QWebEngineView
print('Qt version  :', QT_VERSION_STR)
print('PyQt5 import: OK')
print('WebEngine   :', QWebEngineView.__name__)
PYCHECK

log "Creating application directory at ${APP_DIR}"
mkdir -p "${APP_DIR}"

cat > "${BACKEND_PL}" <<PLEND
:- use_module(library(http/http_server)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(library(filesex)).

app_dir('${APP_DIR}').
default_home('https://example.org').
max_history(500).

:- http_handler(root(api/ping), api_ping, [method(get)]).
:- http_handler(root(api/home), api_home_get, [method(get)]).
:- http_handler(root(api/home/set), api_home_set, [method(get)]).
:- http_handler(root(api/history/list), api_history_list, [method(get)]).
:- http_handler(root(api/history/add), api_history_add, [method(get)]).
:- http_handler(root(api/bookmarks/list), api_bookmarks_list, [method(get)]).
:- http_handler(root(api/bookmarks/add), api_bookmarks_add, [method(get)]).
:- http_handler(root(api/bookmarks/delete), api_bookmarks_delete, [method(get)]).

main(Argv) :-
    ensure_store,
    parse_port(Argv, Port),
    format('Starting SWI-Prolog browser backend on http://127.0.0.1:~w~n', [Port]),
    flush_output,
    http_server(http_dispatch, [port(localhost:Port)]),
    thread_get_message(stop).

parse_port([Atom|_], Port) :-
    atom_number(Atom, Port), !.
parse_port(_, 18472).

ensure_store :-
    app_dir(Dir),
    make_directory_path(Dir),
    default_home(Default),
    ensure_json_file('home.json', _{url:Default}),
    ensure_json_file('history.json', []),
    ensure_json_file('bookmarks.json', []).

ensure_json_file(Name, Default) :-
    store_file(Name, File),
    (   exists_file(File)
    ->  true
    ;   write_json_file(File, Default)
    ).

store_file(Name, File) :-
    app_dir(Dir),
    directory_file_path(Dir, Name, File).

read_json_file(File, Default, Data) :-
    (   exists_file(File)
    ->  catch(
            setup_call_cleanup(
                open(File, read, In),
                json_read_dict(In, Data),
                close(In)
            ),
            _,
            Data = Default
        )
    ;   Data = Default
    ).

write_json_file(File, Data) :-
    setup_call_cleanup(
        open(File, write, Out),
        json_write_dict(Out, Data, [width(0)]),
        close(Out)
    ).

utc_now(Stamp) :-
    get_time(Now),
    format_time(atom(Stamp), '%FT%TZ', Now).

same_url(URL, Dict) :-
    get_dict(url, Dict, URL).

prepend_limited(Entry, List, Max, [Entry|Trimmed]) :-
    Max1 is Max - 1,
    length(Trimmed, Max1),
    append(Trimmed, _, List), !.
prepend_limited(Entry, List, _Max, [Entry|List]).

api_ping(_Request) :-
    reply_json_dict(_{ok:true}).

api_home_get(_Request) :-
    store_file('home.json', File),
    default_home(Default),
    read_json_file(File, _{url:Default}, Data),
    reply_json_dict(Data).

api_home_set(Request) :-
    http_parameters(Request, [url(URL, [string])]),
    store_file('home.json', File),
    write_json_file(File, _{url:URL}),
    reply_json_dict(_{ok:true, url:URL}).

api_history_list(_Request) :-
    store_file('history.json', File),
    read_json_file(File, [], Items),
    reply_json_dict(_{items:Items}).

api_history_add(Request) :-
    http_parameters(Request,
                    [ url(URL,   [string]),
                      title(Title,[string, default('')])
                    ]),
    store_file('history.json', File),
    read_json_file(File, [], Old0),
    utc_now(TS),
    Entry = _{url:URL, title:Title, ts:TS},
    exclude(same_url(URL), Old0, Old1),
    max_history(Max),
    prepend_limited(Entry, Old1, Max, New),
    write_json_file(File, New),
    reply_json_dict(_{ok:true}).

api_bookmarks_list(_Request) :-
    store_file('bookmarks.json', File),
    read_json_file(File, [], Items),
    reply_json_dict(_{items:Items}).

api_bookmarks_add(Request) :-
    http_parameters(Request,
                    [ url(URL,   [string]),
                      title(Title,[string, default('')])
                    ]),
    store_file('bookmarks.json', File),
    read_json_file(File, [], Old0),
    utc_now(TS),
    Entry = _{url:URL, title:Title, ts:TS},
    exclude(same_url(URL), Old0, Old1),
    New = [Entry|Old1],
    write_json_file(File, New),
    reply_json_dict(_{ok:true}).

api_bookmarks_delete(Request) :-
    http_parameters(Request, [url(URL, [string])]),
    store_file('bookmarks.json', File),
    read_json_file(File, [], Old0),
    exclude(same_url(URL), Old0, New),
    write_json_file(File, New),
    reply_json_dict(_{ok:true}).

:- initialization(main, main).
PLEND

cat > "${FRONTEND_PY}" <<'PYEND'
#!/usr/bin/python3
import json
import sys
import urllib.parse
import urllib.request
from typing import Dict, List, Optional

from PyQt5.QtCore import QUrl, Qt
from PyQt5.QtWidgets import (
    QAction,
    QApplication,
    QLabel,
    QLineEdit,
    QListWidget,
    QMainWindow,
    QMessageBox,
    QStatusBar,
    QTabWidget,
    QToolBar,
    QVBoxLayout,
    QWidget,
)
from PyQt5.QtWebEngineWidgets import QWebEngineProfile, QWebEngineSettings, QWebEngineView


class ApiClient:
    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip('/')

    def _fetch_json(self, path: str, params: Optional[Dict[str, str]] = None) -> Dict:
        query = ''
        if params:
            query = '?' + urllib.parse.urlencode(params)
        url = f'{self.base_url}{path}{query}'
        request = urllib.request.Request(url, headers={'User-Agent': 'PrologMultimediaBrowser/1.0'})
        with urllib.request.urlopen(request, timeout=10) as response:
            return json.loads(response.read().decode('utf-8'))

    def get_home(self) -> str:
        try:
            data = self._fetch_json('/api/home')
            return str(data.get('url') or 'https://example.org')
        except Exception:
            return 'https://example.org'

    def set_home(self, url: str) -> None:
        self._fetch_json('/api/home/set', {'url': url})

    def add_history(self, url: str, title: str) -> None:
        self._fetch_json('/api/history/add', {'url': url, 'title': title})

    def get_history(self) -> List[Dict]:
        data = self._fetch_json('/api/history/list')
        return list(data.get('items', []))

    def add_bookmark(self, url: str, title: str) -> None:
        self._fetch_json('/api/bookmarks/add', {'url': url, 'title': title})

    def get_bookmarks(self) -> List[Dict]:
        data = self._fetch_json('/api/bookmarks/list')
        return list(data.get('items', []))

    def delete_bookmark(self, url: str) -> None:
        self._fetch_json('/api/bookmarks/delete', {'url': url})


class BrowserView(QWebEngineView):
    def __init__(self, main_window: 'BrowserWindow') -> None:
        super().__init__()
        self.main_window = main_window
        self.apply_settings()
        self.titleChanged.connect(self._on_title_changed)
        self.urlChanged.connect(self._on_url_changed)
        self.loadFinished.connect(self._on_load_finished)
        self.page().fullScreenRequested.connect(self.main_window.handle_fullscreen_request)

    def apply_settings(self) -> None:
        settings = self.settings()
        settings.setAttribute(QWebEngineSettings.JavascriptEnabled, True)
        settings.setAttribute(QWebEngineSettings.PluginsEnabled, True)
        settings.setAttribute(QWebEngineSettings.FullScreenSupportEnabled, True)
        settings.setAttribute(QWebEngineSettings.PlaybackRequiresUserGesture, False)
        settings.setAttribute(QWebEngineSettings.AutoLoadIconsForPage, True)
        settings.setAttribute(QWebEngineSettings.LocalStorageEnabled, True)
        settings.setAttribute(QWebEngineSettings.LocalContentCanAccessRemoteUrls, True)

    def createWindow(self, _window_type):
        return self.main_window.add_tab(QUrl('about:blank'), 'New Tab', switch_to=True)

    def _on_title_changed(self, title: str) -> None:
        index = self.main_window.tabs.indexOf(self)
        if index >= 0:
            self.main_window.tabs.setTabText(index, title[:40] or 'New Tab')
        if self is self.main_window.current_view_or_none():
            self.main_window.setWindowTitle((title or 'Prolog Multimedia Browser') + ' - Prolog Multimedia Browser')

    def _on_url_changed(self, qurl: QUrl) -> None:
        if self is self.main_window.current_view_or_none():
            self.main_window.address_bar.setText(qurl.toString())

    def _on_load_finished(self, ok: bool) -> None:
        if not ok:
            return
        url = self.url().toString()
        title = self.title() or url
        try:
            self.main_window.api.add_history(url, title)
        except Exception:
            pass


class BrowserWindow(QMainWindow):
    def __init__(self, api_base: str) -> None:
        super().__init__()
        self.api = ApiClient(api_base)
        self.tabs = QTabWidget()
        self.tabs.setDocumentMode(True)
        self.tabs.setTabsClosable(True)
        self.tabs.setMovable(True)
        self.tabs.currentChanged.connect(self.on_current_tab_changed)
        self.tabs.tabCloseRequested.connect(self.close_tab)
        self.setCentralWidget(self.tabs)
        self.address_bar = QLineEdit()
        self.address_bar.setClearButtonEnabled(True)
        self.status = QStatusBar()
        self.setStatusBar(self.status)
        self._child_windows = []
        self._build_toolbar()
        self._build_menus()
        self.resize(1360, 900)
        self.setWindowTitle('Prolog Multimedia Browser')

        profile = QWebEngineProfile.defaultProfile()
        profile.setPersistentCookiesPolicy(QWebEngineProfile.ForcePersistentCookies)

        home = self.api.get_home()
        self.add_tab(QUrl(home), 'Home', switch_to=True)

    def _build_toolbar(self) -> None:
        nav = QToolBar('Navigation')
        nav.setMovable(False)
        self.addToolBar(nav)

        back_action = QAction('Back', self)
        back_action.triggered.connect(lambda: self.current_view().back())
        nav.addAction(back_action)

        forward_action = QAction('Forward', self)
        forward_action.triggered.connect(lambda: self.current_view().forward())
        nav.addAction(forward_action)

        reload_action = QAction('Reload', self)
        reload_action.triggered.connect(lambda: self.current_view().reload())
        nav.addAction(reload_action)

        home_action = QAction('Home', self)
        home_action.triggered.connect(self.go_home)
        nav.addAction(home_action)

        new_tab_action = QAction('New Tab', self)
        new_tab_action.triggered.connect(lambda: self.add_tab(QUrl(self.api.get_home()), 'New Tab', switch_to=True))
        nav.addAction(new_tab_action)

        bookmark_action = QAction('Bookmark', self)
        bookmark_action.triggered.connect(self.add_current_bookmark)
        nav.addAction(bookmark_action)

        set_home_action = QAction('Set Home', self)
        set_home_action.triggered.connect(self.set_current_home)
        nav.addAction(set_home_action)

        nav.addWidget(QLabel(' URL: '))
        self.address_bar.returnPressed.connect(self.navigate_to_address)
        nav.addWidget(self.address_bar)

    def _build_menus(self) -> None:
        menu = self.menuBar()

        file_menu = menu.addMenu('File')
        new_tab = QAction('New Tab', self)
        new_tab.triggered.connect(lambda: self.add_tab(QUrl(self.api.get_home()), 'New Tab', switch_to=True))
        file_menu.addAction(new_tab)

        close_tab_action = QAction('Close Tab', self)
        close_tab_action.triggered.connect(lambda: self.close_tab(self.tabs.currentIndex()))
        file_menu.addAction(close_tab_action)

        exit_action = QAction('Exit', self)
        exit_action.triggered.connect(self.close)
        file_menu.addAction(exit_action)

        library_menu = menu.addMenu('Library')
        show_bookmarks = QAction('Show Bookmarks', self)
        show_bookmarks.triggered.connect(self.show_bookmarks)
        library_menu.addAction(show_bookmarks)

        show_history = QAction('Show History', self)
        show_history.triggered.connect(self.show_history)
        library_menu.addAction(show_history)

    def current_view_or_none(self):
        widget = self.tabs.currentWidget()
        if isinstance(widget, BrowserView):
            return widget
        return None

    def current_view(self) -> BrowserView:
        widget = self.current_view_or_none()
        if widget is None:
            raise RuntimeError('No active browser tab')
        return widget

    def add_tab(self, qurl: QUrl, label: str, switch_to: bool = True) -> BrowserView:
        browser = BrowserView(self)
        index = self.tabs.addTab(browser, label)
        browser.setUrl(qurl)
        if switch_to:
            self.tabs.setCurrentIndex(index)
        return browser

    def close_tab(self, index: int) -> None:
        if self.tabs.count() <= 1:
            return
        widget = self.tabs.widget(index)
        self.tabs.removeTab(index)
        if widget is not None:
            widget.deleteLater()

    def on_current_tab_changed(self, index: int) -> None:
        widget = self.tabs.widget(index)
        if isinstance(widget, BrowserView):
            self.address_bar.setText(widget.url().toString())
            self.setWindowTitle((widget.title() or 'Prolog Multimedia Browser') + ' - Prolog Multimedia Browser')

    def normalize_url(self, text: str) -> QUrl:
        raw = text.strip()
        if not raw:
            return QUrl(self.api.get_home())
        parsed = urllib.parse.urlparse(raw)
        if not parsed.scheme:
            raw = 'https://' + raw
        return QUrl(raw)

    def navigate_to_address(self) -> None:
        self.current_view().setUrl(self.normalize_url(self.address_bar.text()))

    def go_home(self) -> None:
        self.current_view().setUrl(QUrl(self.api.get_home()))

    def add_current_bookmark(self) -> None:
        view = self.current_view()
        url = view.url().toString()
        title = view.title() or url
        try:
            self.api.add_bookmark(url, title)
            self.status.showMessage(f'Bookmarked: {title}', 3000)
        except Exception as exc:
            QMessageBox.warning(self, 'Bookmark Failed', str(exc))

    def set_current_home(self) -> None:
        url = self.current_view().url().toString()
        try:
            self.api.set_home(url)
            self.status.showMessage(f'Home page set to {url}', 3000)
        except Exception as exc:
            QMessageBox.warning(self, 'Set Home Failed', str(exc))

    def _show_items_window(self, title: str, items: List[Dict], allow_delete: bool = False) -> None:
        window = QWidget(self, Qt.Window)
        window.setWindowTitle(title)
        window.resize(900, 600)
        layout = QVBoxLayout(window)
        list_widget = QListWidget(window)
        for item in items:
            item_title = item.get('title') or item.get('url') or '(untitled)'
            item_url = item.get('url') or ''
            item_ts = item.get('ts') or ''
            list_widget.addItem(f'{item_title}\n{item_url}\n{item_ts}')
        layout.addWidget(list_widget)

        def open_selected() -> None:
            row = list_widget.currentRow()
            if row < 0 or row >= len(items):
                return
            url = str(items[row].get('url') or '')
            if url:
                self.current_view().setUrl(QUrl(url))
                window.close()

        list_widget.itemDoubleClicked.connect(lambda _item: open_selected())

        if allow_delete:
            delete_action = QAction('Delete Selected Bookmark', window)

            def delete_selected() -> None:
                row = list_widget.currentRow()
                if row < 0 or row >= len(items):
                    return
                url = str(items[row].get('url') or '')
                if not url:
                    return
                try:
                    self.api.delete_bookmark(url)
                    self.status.showMessage(f'Deleted bookmark: {url}', 3000)
                    window.close()
                except Exception as exc:
                    QMessageBox.warning(self, 'Delete Bookmark Failed', str(exc))

            delete_action.triggered.connect(delete_selected)
            window.addAction(delete_action)
            window.setContextMenuPolicy(Qt.ActionsContextMenu)

        window.show()
        window.raise_()
        window.activateWindow()
        self._child_windows.append(window)

    def show_bookmarks(self) -> None:
        try:
            items = self.api.get_bookmarks()
        except Exception as exc:
            QMessageBox.warning(self, 'Bookmarks', f'Could not load bookmarks: {exc}')
            return
        self._show_items_window('Bookmarks', items, allow_delete=True)

    def show_history(self) -> None:
        try:
            items = self.api.get_history()
        except Exception as exc:
            QMessageBox.warning(self, 'History', f'Could not load history: {exc}')
            return
        self._show_items_window('History', items, allow_delete=False)

    def handle_fullscreen_request(self, request) -> None:
        request.accept()
        if request.toggleOn():
            self.showFullScreen()
        else:
            self.showNormal()


def main() -> int:
    api_base = sys.argv[1] if len(sys.argv) >= 2 else 'http://127.0.0.1:18472'
    app = QApplication(sys.argv)
    app.setApplicationName('Prolog Multimedia Browser')
    window = BrowserWindow(api_base)
    window.show()
    return app.exec_()


if __name__ == '__main__':
    sys.exit(main())
PYEND

chmod u+x "${FRONTEND_PY}"

log "Checking generated frontend syntax with system Python"
env -u PYTHONHOME -u PYTHONPATH "${SYSTEM_PYTHON}" -m py_compile "${FRONTEND_PY}"

log "Checking generated Prolog backend syntax"
if ! swipl -q -g halt -t halt -s "${BACKEND_PL}" >/dev/null 2>"${BACKEND_LOG}.syntax"; then
  printf '\nProlog syntax check failed. Log follows:\n\n' >&2
  sed -n '1,200p' "${BACKEND_LOG}.syntax" >&2 || true
  exit 1
fi
rm -f "${BACKEND_LOG}.syntax"

log "Starting Prolog backend"
cd "${APP_DIR}"
: > "${BACKEND_LOG}"
nohup swipl -q -s "${BACKEND_PL}" -- "${PORT}" >"${BACKEND_LOG}" 2>&1 &
BACKEND_PID="$!"

log "Waiting for backend to accept connections"
if ! env -u PYTHONHOME -u PYTHONPATH "${SYSTEM_PYTHON}" - <<PYWAIT
import json
import sys
import time
import urllib.request
url = 'http://127.0.0.1:${PORT}/api/ping'
for _ in range(120):
    try:
        with urllib.request.urlopen(url, timeout=1) as response:
            data = json.loads(response.read().decode('utf-8'))
            if data.get('ok'):
                sys.exit(0)
    except Exception:
        time.sleep(0.25)
sys.exit(1)
PYWAIT
then
  printf '\nBackend did not start correctly. Backend log follows:\n\n' >&2
  sed -n '1,200p' "${BACKEND_LOG}" >&2 || true
  exit 1
fi

log "Launching internal multimedia browser window"
printf 'Using system Python: %s\n' "${SYSTEM_PYTHON}"
PYTHONNOUSERSITE=1 \
QTWEBENGINE_CHROMIUM_FLAGS='--autoplay-policy=no-user-gesture-required' \
env -u PYTHONHOME -u PYTHONPATH "${SYSTEM_PYTHON}" "${FRONTEND_PY}" "http://127.0.0.1:${PORT}"
