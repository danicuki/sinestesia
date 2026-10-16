#!/usr/bin/env python3
"""Baixa clips de requests da fila fal — recupera runs interrompidos.
Uso: FAL_API_KEY=... python3 fal_fetch.py [request_id ...]"""
import json, os, sys, urllib.request

KEY = os.environ.get("FAL_API_KEY") or sys.exit("defina FAL_API_KEY")
IDS = sys.argv[1:] or [
    "01a08a5d-cb4a-7790-85cb-03fe4e1dd56f",
    "01a08a5d-cc62-76a1-bc60-4fd7e163dc9b",
    "01a08a5d-cd52-7be2-be7b-2feec085dca7",
    "01a08a5d-ce45-7aa2-8637-5dfde60efcbc",
    "01a08a5d-cf36-7b92-bf4c-d9b02f4ab57f",
    "01a08a5d-d026-73c2-89f5-4cfd466f8223",
    "01a08a5d-d110-76d2-8ffd-043f9e2be6fb",
]

def get(url, auth=True):
    h = {"Authorization": f"Key {KEY}"} if auth else {}
    return urllib.request.urlopen(urllib.request.Request(url, headers=h)).read()

for i, rid in enumerate(IDS):
    try:
        data = json.loads(get(f"https://queue.fal.run/minimax/h3-max/requests/{rid}"))
        out = f"fal_scene_{i:02d}.mp4"
        open(out, "wb").write(get(data["video"]["url"], auth=False))
        print(f"scene {i}: {out}  ({data['video'].get('file_size', '?')} bytes)")
    except Exception as e:
        print(f"scene {i} ({rid}): FAILED — {e}")
