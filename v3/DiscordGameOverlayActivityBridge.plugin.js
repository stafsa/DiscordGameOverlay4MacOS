/**
 * @name DiscordGameOverlayActivityBridge
 * @author stafsa
 * @version 0.2.0
 * @description Sends Discord's detected running games to the local Discord overlay bridge.
 */

module.exports = class DiscordGameOverlayActivityBridge {
    constructor() {
        this.endpoint = "http://127.0.0.1:7999/discord-games";
        this.timer = null;
        this.runningGameStore = null;
        this.onRunningGamesChanged = () => this.sendDetectedGames();
        this.lastPayload = "";
        this.settings = {excludedGames: []};
    }

    start() {
        this.loadSettings();
        this.runningGameStore = this.getRunningGameStore();
        if (this.runningGameStore?.addChangeListener) {
            this.runningGameStore.addChangeListener(this.onRunningGamesChanged);
        } else {
            this.timer = setInterval(() => this.sendDetectedGames(), 2000);
            BdApi.Logger.warn("DiscordGameOverlayActivityBridge", "RunningGameStore has no change listener; using polling fallback.");
        }
        this.sendDetectedGames();
        BdApi.UI.showToast("Game activity bridge started.", {type: "success"});
    }

    stop() {
        if (this.timer) clearInterval(this.timer);
        this.timer = null;
        if (this.runningGameStore?.removeChangeListener) {
            this.runningGameStore.removeChangeListener(this.onRunningGamesChanged);
        }
        this.runningGameStore = null;
    }

    loadSettings() {
        const saved = BdApi.Data.load("DiscordGameOverlayActivityBridge", "settings");
        this.settings = {
            excludedGames: Array.isArray(saved?.excludedGames) ? saved.excludedGames : []
        };
    }

    saveSettings() {
        BdApi.Data.save("DiscordGameOverlayActivityBridge", "settings", this.settings);
    }

    setExcludedGames(value) {
        const entries = String(value || "")
            .split(/[\n,]/)
            .map(entry => entry.trim().toLowerCase())
            .filter(Boolean);
        this.settings.excludedGames = [...new Set(entries)];
        this.saveSettings();
        this.lastPayload = "";
        this.sendDetectedGames();
    }

    isExcluded(game) {
        const excluded = new Set(this.settings.excludedGames);
        return excluded.has(game.name.toLowerCase()) || excluded.has(game.id.toLowerCase());
    }

    getSettingsPanel() {
        return BdApi.UI.buildSettingsPanel({
            settings: [{
                id: "excludedGames",
                name: "Excluded games",
                note: "Comma or line separated game names or application IDs. Excluded games are never sent to localhost:7999.",
                type: "text",
                value: this.settings.excludedGames.join(", "),
                placeholder: "Example: Roblox, Minecraft"
            }],
            onChange: (_, id, value) => {
                if (id === "excludedGames") this.setExcludedGames(value);
            }
        });
    }

    getRunningGameStore() {
        return BdApi.Webpack.getStore("RunningGameStore") ||
            BdApi.Webpack.getModule(module => module && typeof module.getRunningGames === "function");
    }

    normalizeGame(game) {
        if (!game || typeof game !== "object") return null;
        const name = game.name || game.displayName || game.applicationName;
        if (!name) return null;
        return {
            id: String(game.id || game.applicationId || ""),
            name: String(name),
            pid: Number(game.pid || game.processId || 0),
            executable: String(game.exePath || game.executablePath || game.path || ""),
            started_at: Number(game.start || game.startTime || 0)
        };
    }

    getDetectedGames() {
        const store = this.getRunningGameStore();
        if (!store) return null;
        const result = store.getRunningGames();
        const games = Array.isArray(result) ? result : Object.values(result || {});
        return games
            .map(game => this.normalizeGame(game))
            .filter(Boolean)
            .filter(game => !this.isExcluded(game));
    }

    async sendDetectedGames() {
        try {
            const games = this.getDetectedGames();
            if (games === null) {
                BdApi.Logger.warn("DiscordGameOverlayActivityBridge", "RunningGameStore is unavailable.");
                return;
            }
            const signature = JSON.stringify(games);
            if (signature === this.lastPayload) return;
            const payload = JSON.stringify({games, sent_at: Date.now()});

            const response = await fetch(this.endpoint, {
                method: "POST",
                headers: {"Content-Type": "text/plain;charset=UTF-8"},
                body: payload
            });
            if (!response.ok && response.status !== 204) {
                throw new Error(`Bridge returned HTTP ${response.status}`);
            }
            this.lastPayload = signature;
        } catch (error) {
            BdApi.Logger.warn("DiscordGameOverlayActivityBridge", "Unable to send detected games.", error);
        }
    }
};
