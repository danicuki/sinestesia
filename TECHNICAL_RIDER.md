# Sinestesia — Technical Rider & Spatial Requirements

This document outlines the space, hardware, lighting, sound, and scheduling requirements for presenting the live AI audiovisual performance **Sinestesia** (Daniella Alcarpe & Dani Cuki).

---

## 1. Spatial & Area Requirements

* **Optimal Stage Area:** 4.0 meters (Width) x 3.0 meters (Depth) x 3.0 meters (Height).
* **Minimum Stage Area:** 3.0 meters (Width) x 2.0 meters (Depth) x 2.5 meters (Height).
* **Projection Surface:** A flat, smooth, matte-white or light-grey back wall, OR a high-quality rear/front projection screen (minimum size: 3.0m x 2.25m, supported ratios: 4:3 or 16:9).
* **Lighting & Blackout:** Near-total blackout on the projection backdrop is critical to ensure optimal contrast of the live AI-generated artwork. 
* **Stage Lighting Restrictions:** All stage lighting must be highly directional (such as profile spots, shutters, or tight zoom fixtures) focused exclusively on the performers' faces and guitar neck. Stage lights must NOT spill or wash out onto the projection surface.

---

## 2. Hardware & Equipment Breakdown

### A) TOURED KIT (Provided by the Artists)
* **1x Apple MacBook Pro** (M4 Max, 48GB Unified Memory) — Runs the Elixir backend orchestrator, the local LLM "Director" (Gemma 12B), and the Three.js WebGL visual engine.
* **1x Acoustic Guitar** — Equipped with an active onboard piezo/pickup system.
* **All necessary interconnect cables** — Including USB-C to USB-B, HDMI cabling, power adapters, and instrument jacks.

### B) VENUE REQUIREMENTS (To be provided by the Local Organizer/Venue)
* **Video Projection:**
  * 1x Professional Video Projector (minimum 8,000 to 10,000 Lumens, Laser/DLP engine preferred for deep color contrast, native resolution 1920x1080 or higher, equipped with an appropriate lens according to stage throw depth).
  * 1x Long High-Speed HDMI cable running from the on-stage performers' table directly to the projector.
* **Audio Capture & Inputs:**
  * 2x High-Quality Vocal Microphone (e.g., Shure SM58 or Neumann KMS 105) on a tall, stable boom stand.
  * 1x Active DI Box (for the acoustic guitar output).
* **Sound Reinforcement & PA:**
  * 1x Stereo PA System, professionally sized and tuned for the venue's acoustic volume.
  * 1x Mixing Console (digital or analog) with a minimum of 4 input channels (Vocals, Guitar) and auxiliary sends.
* **Monitoring:**
  * 2x Stage Monitors (wedges) OR a stereo In-Ear Monitoring (IEM) system with independent monitor mixes for the vocalist and guitarist.
* **Power & Stage Furniture:**
  * 1x Sturdy Table/Stand (minimum dimensions: 100cm Width x 60cm Depth) to house the laptop, audio interface, and tech gear.
  * 1x High Stool (for the guitarist).
  * 2x Standard power outlets (230V Schuko or local national standard socket) located directly at the performers' table.
* **WI-FI Connection:**
  * High quality internet connection for cloud AI models access   
---

## 3. Setup & Soundcheck Timeline

The artists require a total of **60 minutes (1 hour)** of uninterrupted stage access for setup, technical calibration, and soundcheck prior to doors opening, assuming all venue-provided equipment (projector, PA, mic stands) is already rigged, patched, and fully functional.

* **00:00 – 00:20 | Technical Rigging & Projection Alignment**  
  Setting up stage furniture, laptop, and audio interface. Establishing HDMI connection to the venue projector, executing focus adjustments, resolution mapping, and aligning the WebGL canvas edges with the backdrop.
* **00:20 – 00:40 | Audio Routing & Line-Check**  
  Routing vocal microphone and acoustic guitar signals through the mixing desk and audio interface. Setting gain stages, leveling monitor mixes, and performing feedback tests.
* **00:40 – 01:00 | Rehearsal & Lighting Adjustments**  
  Executing a full-dress performance of one or two songs. Adjusting directional stage spotlights to guarantee performer visibility without compromising projection contrast. Final tuning of Three.js shader parameters.

---

## 4. Contacts & References

* **Vocalist & Artistic Curator:** Daniella Alcarpe
* **Guitarist & System Engineer:** Daniel Cukier
* **Showreel (90s):** [Watch on YouTube](https://youtu.be/BnoYW_fPRuE)
* **Live Demo Video Reference:** [Watch on YouTube (NFC Summit Lisbon)](https://www.youtube.com/watch?v=c_ZsERk0Al8)
* **Open-Source Codebase:** [github.com/danicuki/sinestesia](https://github.com/danicuki/sinestesia)
