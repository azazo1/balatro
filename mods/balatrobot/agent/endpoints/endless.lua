-- 本仓库新增: 胜利界面上选择 "无尽模式", 等同点击界面上的按钮, 然后等回合结算显示出 cash_out 按钮.

---@type Endpoint
return {
  name = "endless",

  description = "Close the win screen and keep playing in endless mode",

  schema = {},

  requires_state = { G.STATES.ROUND_EVAL },

  ---@param _ table
  ---@param send_response fun(response: Response.Endpoint)
  execute = function(_, send_response)
    if BB_OVERLAY.kind() ~= "win" then
      send_response({ message = "The win screen is not open", name = BB_ERROR_NAMES.INVALID_STATE })
      return
    end
    G.FUNCS.exit_overlay_menu()

    -- 关掉弹窗后, 暂停前停着的结算事件继续执行, 结算完成时出现 cash_out 按钮.
    G.E_MANAGER:add_event(Event({
      trigger = "condition",
      blocking = false,
      blockable = false,
      func = function()
        if G.STATE ~= G.STATES.ROUND_EVAL or not G.round_eval or G.CONTROLLER.locked then
          return false
        end
        -- 只认挂在本次结算界面上的按钮: 之前的结算留下的按钮盒子可能还在 G.I.UIBOX 里,
        -- 认错会在结算行还没加完时返回, 紧接着的 cash_out 删掉 round_eval, 剩下的结算行事件就会崩溃.
        for _, box in ipairs(G.I.UIBOX) do
          if box.config and box.config.major == G.round_eval and box:get_UIE_by_ID("cash_out_button") then
            send_response(BB_GAMESTATE.get_gamestate())
            return true
          end
        end
        return false
      end,
    }))
  end,
}
