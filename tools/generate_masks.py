import base64
import io
from PIL import Image, ImageDraw, ImageFilter

PLACEMENTS = {
    "top-left": (0.25, 0.28),
    "top": (0.50, 0.26),
    "top-right": (0.75, 0.28),
    "left": (0.25, 0.52),
    "center": (0.50, 0.50),
    "right": (0.75, 0.52),
    "bottom-left": (0.25, 0.74),
    "bottom": (0.50, 0.76),
    "bottom-right": (0.75, 0.74),
}

DEFAULT_WIDTH = 768
DEFAULT_HEIGHT = 432
ELLIPSE_RX = 0.22
ELLIPSE_RY = 0.28
MASK_FEATHER_PX = 24

def build_mask(placement):
    cx_f, cy_f = PLACEMENTS[placement]
    w, h = DEFAULT_WIDTH, DEFAULT_HEIGHT
    cx, cy = cx_f * w, cy_f * h
    rx, ry = ELLIPSE_RX * w, ELLIPSE_RY * h

    mask = Image.new("L", (w, h), 0)
    ImageDraw.Draw(mask).ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=255)
    return mask.filter(ImageFilter.GaussianBlur(MASK_FEATHER_PX))

elixir_code = """defmodule Sinestesia.ImageGen.Masks do
  @moduledoc \"\"\"
  Pre-generated 768x432 soft ellipse masks for the 9 placement regions.
  Base64-encoded PNG data URLs for fal.ai Flux inpainting.
  \"\"\"

  def get_mask(placement) do
    Map.get(masks(), placement, Map.fetch!(masks(), "center"))
  end

  defp masks do
    %{
"""

for p, coords in PLACEMENTS.items():
    img = build_mask(p)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    b64 = base64.b64encode(buf.getvalue()).decode("utf-8")
    elixir_code += f'      "{p}" => "data:image/png;base64,{b64}",\n'

elixir_code += """    }
  end
end
"""

with open("backend/lib/sinestesia/image_gen/masks.ex", "w") as f:
    f.write(elixir_code)

print("Generated backend/lib/sinestesia/image_gen/masks.ex successfully.")
