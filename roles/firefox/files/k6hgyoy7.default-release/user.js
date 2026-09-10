// Von scripts/capture-firefox.sh generiert - nicht von Hand pflegen.
// Firefox liest user.js bei jedem Start als Override-Schicht ueber prefs.js -
// deshalb hier statt eines fragilen prefs.js-Merges waehrend des Chroot-Laufs
// (Firefox laeuft zu diesem Zeitpunkt noch gar nicht).
user_pref("accessibility.typeaheadfind.flashBar", 0);
user_pref("browser.bookmarks.addedImportButton", true);
user_pref("browser.bookmarks.restore_default_bookmarks", false);
user_pref("browser.contentblocking.category", "standard");
user_pref("browser.download.panel.shown", true);
user_pref("browser.download.viewableInternally.typeWasRegistered.avif", true);
user_pref("browser.download.viewableInternally.typeWasRegistered.webp", true);
user_pref("browser.eme.ui.firstContentShown", true);
user_pref("browser.pageActions.persistedActions", "{\"ids\":[\"bookmark\"],\"idsInUrlbar\":[\"bookmark\"],\"idsInUrlbarPreProton\":[],\"version\":1}");
user_pref("browser.theme.toolbar-theme", 0);
user_pref("browser.translations.mostRecentTargetLanguages", "en");
user_pref("browser.translations.neverTranslateLanguages", "de");
user_pref("browser.uiCustomization.state", "{\"placements\":{\"widget-overflow-fixed-list\":[],\"unified-extensions-area\":[],\"nav-bar\":[\"sidebar-button\",\"back-button\",\"forward-button\",\"stop-reload-button\",\"customizableui-special-spring1\",\"vertical-spacer\",\"urlbar-container\",\"customizableui-special-spring2\",\"downloads-button\",\"ipprotection-button\",\"fxa-toolbar-menu-button\",\"reset-pbm-toolbar-button\",\"unified-extensions-button\",\"_446900e4-71c2-419f-a6a7-df9c091e268b_-browser-action\",\"_6764c0b0-a70e-49dd-846c-c422fad35eec_-browser-action\"],\"toolbar-menubar\":[\"menubar-items\"],\"TabsToolbar\":[\"tabbrowser-tabs\",\"new-tab-button\",\"customizableui-special-spring3\",\"alltabs-button\",\"ai-window-toggle\"],\"vertical-tabs\":[],\"PersonalToolbar\":[\"import-button\",\"personal-bookmarks\"]},\"seen\":[\"reset-pbm-toolbar-button\",\"developer-button\",\"screenshot-button\",\"ipprotection-button\",\"_446900e4-71c2-419f-a6a7-df9c091e268b_-browser-action\",\"_6764c0b0-a70e-49dd-846c-c422fad35eec_-browser-action\",\"ai-window-toggle\"],\"dirtyAreaCache\":[\"nav-bar\",\"vertical-tabs\",\"PersonalToolbar\",\"unified-extensions-area\",\"toolbar-menubar\",\"TabsToolbar\"],\"currentVersion\":26,\"newElementCount\":3}");
user_pref("devtools.debugger.prefs-schema-version", 11);
user_pref("devtools.everOpened", true);
user_pref("devtools.inspector.activeSidebar", "compatibilityview");
user_pref("devtools.inspector.selectedSidebar", "compatibilityview");
user_pref("devtools.netmonitor.columnsData", "[{\"name\":\"override\",\"minWidth\":20,\"width\":2},{\"name\":\"status\",\"minWidth\":30,\"width\":5.56},{\"name\":\"method\",\"minWidth\":30,\"width\":5.56},{\"name\":\"domain\",\"minWidth\":30,\"width\":11.11},{\"name\":\"file\",\"minWidth\":30,\"width\":27.78},{\"name\":\"url\",\"minWidth\":30,\"width\":25},{\"name\":\"initiator\",\"minWidth\":30,\"width\":11.11},{\"name\":\"type\",\"minWidth\":30,\"width\":5.56},{\"name\":\"transferred\",\"minWidth\":30,\"width\":11.11},{\"name\":\"contentSize\",\"minWidth\":30,\"width\":5.56},{\"name\":\"waterfall\",\"minWidth\":150,\"width\":16.67}]");
user_pref("devtools.netmonitor.msg.visibleColumns", "[\"data\",\"time\"]");
user_pref("devtools.responsive.reloadNotification.enabled", false);
user_pref("devtools.responsive.viewport.height", 906);
user_pref("devtools.responsive.viewport.width", 430);
user_pref("devtools.toolbox.footer.height", 218);
user_pref("devtools.toolsidebar-height.inspector", 350);
user_pref("devtools.toolsidebar-width.inspector", 700);
user_pref("devtools.toolsidebar-width.inspector.splitsidebar", 350);
user_pref("dom.forms.autocomplete.formautofill", true);
user_pref("extensions.activeThemeID", "default-theme@mozilla.org");
user_pref("extensions.pictureinpicture.enable_picture_in_picture_overrides", true);
user_pref("general.useragent.override", "Mozilla/5.0 (Macintosh; Intel Mac OS X 15.7; rv:154.0) Gecko/20100101 Firefox/154.0");
user_pref("privacy.clearOnShutdown_v2.formdata", true);
user_pref("sidebar.main.tools", "aichat,syncedtabs,history,bookmarks,{446900e4-71c2-419f-a6a7-df9c091e268b}");
user_pref("sidebar.revamp", true);
user_pref("sidebar.visibility", "hide-on-close");
