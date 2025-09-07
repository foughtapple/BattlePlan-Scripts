-- Create the invisible "End Round" button on this token
self.createButton({
  click_function = "btn_end_round",
  function_owner = self,
  label          = "",
  position       = {0,0.25,0},
  rotation       = {0,180,0},
  width          = 1600,
  height         = 600,
  font_size      = 300,
  color          = {0,0,0,0},   -- invisible background
  font_color     = {0,0,0,0},   -- invisible text
  tooltip        = "Click to end the current round."
})

-- Stub function called when button is clicked
function btn_end_round(obj, player_color, alt_click)
  local target = getObjectFromGUID("a9c4f3")
  if target then
    target.call("end_round", { obj=obj, player=player_color, alt=alt_click })
  else
    print("[EndRound Button] ERROR: Could not find object with GUID a9c4f3")
  end
end
