-- WoW API stubs for LuaLS (minimal set for MidnightUI).
-- This file is only for editor tooling; it is not loaded by the addon.

---@class Frame
---@field EndCaps Frame|nil
---@field BorderArt Frame|nil
---@field Background Frame|nil
---@field SetAlpha fun(self: Frame, alpha: number)
---@field EnableMouse fun(self: Frame, enabled: boolean)
---@field SetFrameStrata fun(self: Frame, strata: string)
---@field SetSize fun(self: Frame, width: number, height: number)
---@field SetAllPoints fun(self: Frame, relativeFrame?: Frame)
---@field SetFrameLevel fun(self: Frame, level: number)
---@field GetFrameLevel fun(self: Frame): number
---@field CreateTexture fun(self: Frame, name?: string, layer?: string, inheritsFrom?: string, subLayer?: number): Texture
---@field shadow Texture|nil
---@field bg Texture|nil
---@field vignette Texture|nil
---@field outerBorder Texture|nil
---@field mainBorder Texture|nil
---@field innerHighlight Texture|nil
---@field topShine Texture|nil
---@field edgeGlow Texture|nil
---@field glowFrame Frame|nil
function Frame() end

---@class Texture
---@field SetAllPoints fun(self: Texture, relativeFrame?: Frame)
---@field SetAlpha fun(self: Texture, alpha: number)
---@field SetBlendMode fun(self: Texture, mode: string)
---@field SetTexture fun(self: Texture, texture: string|number)
---@field SetVertexColor fun(self: Texture, r: number, g: number, b: number, a?: number)
---@field SetSize fun(self: Texture, width: number, height: number)
---@field SetPoint fun(self: Texture, point: string, relativeFrame?: Frame, relativePoint?: string, xOfs?: number, yOfs?: number)
---@field SetDrawLayer fun(self: Texture, layer: string, subLevel?: number)
function Texture() end

---@class Color
function Color() end

---@param frameType string
---@param name? string
---@param parent? Frame
---@param template? string
---@return Frame
function CreateFrame(frameType, name, parent, template) end

---@param unit string
---@return string, string
function UnitClass(unit) end

---@param key string
---@param prefix? string
---@return string
function GetBindingText(key, prefix) end

---@param command string
---@return string
function GetBindingKey(command) end

---@return boolean
function InCombatLockdown() end

---@return Color
function CreateColor(r, g, b, a) end

---@type Frame
UIParent = UIParent

---@type Frame
MainMenuBar = MainMenuBar

---@type Frame
MainMenuBarArtFrame = MainMenuBarArtFrame

---@type Frame
MultiBarBottomLeft = MultiBarBottomLeft

---@type Frame
MultiBarBottomRight = MultiBarBottomRight

---@type Frame
MultiBarRight = MultiBarRight

---@type Frame
MultiBarLeft = MultiBarLeft

---@type Frame
MultiBar5 = MultiBar5

---@type Frame
MultiBar6 = MultiBar6

---@type Frame
MultiBar7 = MultiBar7

---@type Frame
ActionBar1 = ActionBar1

---@type Frame
ActionBar2 = ActionBar2

---@type Frame
ActionBar3 = ActionBar3

---@type Frame
ActionBar4 = ActionBar4

---@type Frame
ActionBar5 = ActionBar5

---@type Frame
ActionBar6 = ActionBar6

---@type Frame
ActionBar7 = ActionBar7

---@type Frame
ActionBar8 = ActionBar8

---@type Frame
ActionBarController = ActionBarController

---@type Frame
ActionBarButtonEventsFrame = ActionBarButtonEventsFrame

---@type Frame
MainActionBar = MainActionBar

---@type Frame
MainActionBarArtFrame = MainActionBarArtFrame

---@type Frame
MainActionBarButtonContainer = MainActionBarButtonContainer

---@type Frame
MainActionBarButtonContainer0 = MainActionBarButtonContainer0

---@type Frame
MainActionBarButtonContainer1 = MainActionBarButtonContainer1

---@type Frame
MainActionBarButtonContainer2 = MainActionBarButtonContainer2

---@type Frame
MainActionBarButtonContainer3 = MainActionBarButtonContainer3

---@type Frame
MainActionBarButtonContainer4 = MainActionBarButtonContainer4

---@type Frame
MainActionBarButtonContainer5 = MainActionBarButtonContainer5

---@type Frame
MainActionBarButtonContainer6 = MainActionBarButtonContainer6

---@type Frame
MainActionBarButtonContainer7 = MainActionBarButtonContainer7

---@type Frame
MainActionBarButtonContainer8 = MainActionBarButtonContainer8

---@type Frame
MicroMenuContainer = MicroMenuContainer

---@type Frame
MainMenuBarVehicleLeaveButton = MainMenuBarVehicleLeaveButton

---@type Frame
SpellbookMicroButton = SpellbookMicroButton

---@type Frame
CharacterMicroButton = CharacterMicroButton

---@type Frame
TalentMicroButton = TalentMicroButton

---@type Frame
AchievementMicroButton = AchievementMicroButton

---@type Frame
QuestLogMicroButton = QuestLogMicroButton

---@type Frame
GuildMicroButton = GuildMicroButton

---@type Frame
LFDMicroButton = LFDMicroButton

---@type Frame
CollectionsMicroButton = CollectionsMicroButton

---@type Frame
EJMicroButton = EJMicroButton

---@type Frame
StoreMicroButton = StoreMicroButton

---@type Frame
MainMenuMicroButton = MainMenuMicroButton

---@type Frame
ChatFrame1 = ChatFrame1

---@type Frame
ChatFrame1Background = ChatFrame1Background

---@type Frame
ChatFrame1FontStringContainer = ChatFrame1FontStringContainer

---@type Frame
StatusTrackingBarManager = StatusTrackingBarManager

_G = _G
