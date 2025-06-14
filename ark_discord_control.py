import discord
import subprocess
import asyncio
import re
import json
from pathlib import Path
from discord.ext import commands, tasks
from datetime import datetime

# === Konfiguration ===
configfile = Path(__file__).resolve().parent / "ark_discord_control_config.json"
print(Path(__file__).resolve().parent)
print(configfile)
with open(configfile, "r") as f:
    config = json.load(f)

ASA_MANAGER_PATH = config["general"]["asa_manager_path"]
TOKEN = config["general"]["token"]
ADMIN_CHANNEL_ID = config["general"]["admin_channel_id"]
ADMIN_ROLE = config["general"]["admin_role"]
COMMAND_PREFIX = config["general"]["command_prefix"]
STATUS_CHANNEL_ID = config["general"]["status_channel_id"]
STATUS_MESSAGE_ID = config["general"]["status_message_id"]

COMMAND_MAP = {
    k: (v["shell"], v["description"], v["role"])
    for k, v in config.get("commands", {}).items()
}

COMMAND_MAP_ALL = {
    k: (v["shell"], v["description"], v["role"])
    for k, v in config.get("commands_all", {}).items()
}

INSTANCE_MAP = {
    k: (v["shell"], v["description"], v["role"])
    for k, v in config.get("instance_commands", {}).items()
}

# Discord Intents
intents = discord.Intents.default()
intents.message_content = True
intents.members = True

bot = commands.Bot(command_prefix=COMMAND_PREFIX, intents=intents)

def save_config(cfg):
    with open(configfile, "w") as f:
        json.dump(cfg, f, indent=4)

async def run_command(cmd):
    proc = await asyncio.create_subprocess_shell(
        cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE
    )
    stdout, stderr = await proc.communicate()
    return proc.returncode, stdout.decode(), stderr.decode()

# ANSI-Strip Funktion
def strip_ansi_codes(text):
    ansi_escape = re.compile(r'\x1B\[[0-?]*[ -/]*[@-~]')
    return ansi_escape.sub('', text)

def split_message_into_blocks(text, max_length=1900):
    lines = text.splitlines()
    blocks = []
    current_block = ""

    for line in lines:
        if len(current_block) + len(line) + 1 > max_length:
            blocks.append(current_block)
            current_block = line
        else:
            current_block += ("\n" if current_block else "") + line

    if current_block:
        blocks.append(current_block)

    return blocks

async def get_available_instances():
    code, out, err = await run_command("/home/ark/.local/bin/asa-manager list_instances")
    if code == 0:
        clean = strip_ansi_codes(out)
        lines = clean.strip().splitlines()
        return [
            line.strip() for line in lines
            if line and "available instances:" not in line.lower()
        ]
    return []

def user_has_permission(user, required_role: str):
    if any(role.name == ADMIN_ROLE for role in user.roles):
        return True
    if not required_role:  # leere Rolle = nur Admins
        return False
    return any(role.name == required_role for role in user.roles)

@bot.event
async def on_ready():
    print(f"✅ Bot ist online als {bot.user}")
    update_embed.start()

@bot.event
async def on_message(message):
    if message.author.bot:
        return
    if message.channel.id != ADMIN_CHANNEL_ID:
        return

    # Rollenprüfung
    if not any(role.name == ADMIN_ROLE for role in message.author.roles):
        await message.channel.send("❌ Du hast nicht die erforderliche Berechtigung.")
        return

    content = message.content.strip()
    if content.startswith(COMMAND_PREFIX):
        content = content[len(COMMAND_PREFIX):].strip()  
    else:
        return
    parts = content.split()
    cmd = parts[0] if len(parts) > 0 else None
    arg = parts[1] if len(parts) > 1 else None

    # Kein Befehl erkannt
    if not cmd:
        return

    if cmd.lower() == "info":
        info_lines = ["📘 **Verfügbare Befehle:**\n"]

        # 1. Ohne Instanz
        info_lines.append("🔧 **Befehle ohne Instanz:**")
        for key, (shell_cmd, description, _) in COMMAND_MAP.items():
            info_lines.append(f"• `{COMMAND_PREFIX}{key}` – {description}")

        # 2. Mit all
        info_lines.append("\n📦 **Befehle mit `all` als Instanz:**")
        for key, (shell_cmd, description, _) in COMMAND_MAP_ALL.items():
            info_lines.append(f"• `{COMMAND_PREFIX}{key} all` – {description}")

        # 3. Für einzelne Instanzen (nur Beschreibung hier)
        info_lines.append("\n📦 **Befehle mit Instanz:**")
        for key, (shell_cmd, description, _) in INSTANCE_MAP.items():
            info_lines.append(f"• `{COMMAND_PREFIX}{key} <instanz>` – {description}")

        response = "\n".join(info_lines)
        blocks = split_message_into_blocks(response)
        for block in blocks:
            await message.channel.send(block)
        return

    elif cmd.lower() == "instances":
        instances = await get_available_instances()
        if not instances:
            await message.channel.send("⚠️ Keine Instanzen gefunden.")
            return

        inst_text = "\n".join(f"• `{name}`" for name in instances)
        await message.channel.send(f"🧾 **Verfügbare Instanzen:**\n{inst_text}")
        return

    # 1. Kommandos ohne Argumente
    elif cmd.lower() in COMMAND_MAP and not arg:
        shell_part, _, required_role = COMMAND_MAP[cmd.lower()]
        if not user_has_permission(message.author, required_role):
            await message.channel.send(f"❌ Du benötigst die Rolle `{required_role}` oder `{ADMIN_ROLE}` für diesen Befehl.")
            return
        
        shell_command = f"{ASA_MANAGER_PATH} {shell_part}"
            
    # 2. Spezialfall: all → nutze Mapping
    elif arg and arg.lower() == "all" and cmd.lower() in COMMAND_MAP_ALL:
        shell_part, _, required_role = COMMAND_MAP_ALL[cmd.lower()]
        if not user_has_permission(message.author, required_role):
            await message.channel.send(f"❌ Du benötigst die Rolle `{required_role}` oder `{ADMIN_ROLE}` für diesen Befehl.")
            return

        shell_command = f"{ASA_MANAGER_PATH} {shell_part}"

    # 3. Instanzbefehle
    elif cmd.lower() in INSTANCE_MAP and arg:
        safe_instance = re.sub(r'[^a-zA-Z0-9_-]', '', arg)
        available_instances = await get_available_instances()

        if safe_instance not in available_instances:
            await message.channel.send(f"❌ Die Instanz `{safe_instance}` wurde nicht gefunden.\n🔍 Nutze `{COMMAND_PREFIX}instances`, um alle gültigen Instanzen zu sehen.")
            return

        shell_part, _, required_role = INSTANCE_MAP[cmd.lower()]

        if not user_has_permission(message.author, required_role):
            await message.channel.send(f"❌ Du benötigst die Rolle `{required_role}` oder `{ADMIN_ROLE}` für diesen Befehl.")
            return

        shell_command = f"{ASA_MANAGER_PATH} {safe_instance} {shell_part}"
        
    else:
        await message.channel.send(f"❌ Befehl unbekannt oder unvollständig.\nℹ️ Gib `{COMMAND_PREFIX}info` ein für eine Übersicht aller gültigen Befehle.")
        return

    try:
        await message.channel.send("⏳ Befehl wird ausgeführt... Je nach Befehl kann das mehrere Minuten dauern. Bitte warte auf die Rückmeldung!")
        #await message.channel.send(shell_command)
        code, out, err = await run_command(shell_command)
        output = out if code == 0 else err
        clean_output = strip_ansi_codes(output)
        blocks = split_message_into_blocks(clean_output)

        for i, block in enumerate(blocks):
            header = f"[Teil {i+1}/{len(blocks)}]\n" if len(blocks) > 1 else ""
            await message.channel.send(f"```{header}{block}```")

    except Exception as e:
        await message.channel.send(f"❌ Fehler: {str(e)}")

@tasks.loop(minutes=10)
async def update_embed():
    channel = bot.get_channel(STATUS_CHANNEL_ID)
    now = datetime.now()
    date_time = now.strftime("%d.%m.%Y %H:%M:%S")

    code, out, err = await run_command(f"{ASA_MANAGER_PATH} show_running")
    output = out if code == 0 else err
    clean_output_running = strip_ansi_codes(output)

    lines = clean_output_running.strip().splitlines()

    # Entferne erste und letzte Zeile, falls vorhanden
    if lines and lines[0].startswith("Checking running instances"):
        lines.pop(0)
    if lines and (
        lines[-1].startswith("No instances") or
        lines[-1].startswith("Total running instances")
    ):
        lines.pop()
    clean_output_running = "\n".join(lines)

    code, out, err = await run_command(f"{ASA_MANAGER_PATH} send_rcon listplayers")
    output_players = out if code == 0 else err
    clean_output_players = strip_ansi_codes(output_players)

    lines = clean_output_players.strip().splitlines()
    current_map = None
    players_by_map = {}
    max_slots = 20

    for line in lines:
        if line.startswith("Sending listplayers to "):
            current_map = line.replace("Sending listplayers to ", "").strip()
        elif line.strip() == "No Players Connected":
            players_by_map[current_map] = []
            current_map = None
        elif current_map and ". " in line:
            parts = line.split(". ", 1)
            if len(parts) > 1:
                name = parts[1].split(",")[0].strip()
                players_by_map.setdefault(current_map, []).append(name)

    if channel:
        embed = discord.Embed(
            title="BissFest Serverstatus",
            description=date_time,
            color=discord.Color.blurple()
        )
        embed.add_field(name="Server:", value=clean_output_running, inline=False)
        for map_name, players in players_by_map.items():
            count = len(players)
            header = f"{map_name} ({count}/{max_slots})"
            if count > 0:
                value = "\n".join(players)
            else:
                value = "keine Spieler verbunden"
            embed.add_field(name=header, value=value, inline=False)

        try:
            if STATUS_MESSAGE_ID:
                message = await channel.fetch_message(int(STATUS_MESSAGE_ID))
                await message.edit(embed=embed)
            else:
                raise discord.NotFound(None, None)  # Trigger neue Nachricht

        except discord.NotFound:
            message = await channel.send(embed=embed)
            config["general"]["status_message_id"] = message.id
            save_config(config)
            print(f"✅ Neue Nachricht gesendet und ID gespeichert: {message.id}")
        except Exception as e:
            print(f"❌ Fehler beim Aktualisieren: {e}")

# Bot starten
bot.run(TOKEN)
