using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using BepInEx;
using UnityEngine;

namespace Munin
{
    /// <summary>
    /// Adds the console command <c>munin_export</c>, which asks the game's own world
    /// generator for the terrain of every explored zone and writes it to a file the
    /// Munin app reads. Saves keep only the player's edits to the terrain;
    /// the terrain itself is regenerated from the seed, so this is the one way to get
    /// it exactly. Read-only: it changes nothing in the world.
    ///
    /// Output (little-endian), ~/Library/Application Support/Munin/terrain/&lt;world&gt;.terrain:
    ///   "MUNT", int32 version (2), int32 zone size (64), int32 samples per side (65), int32 zone count,
    ///   then per zone: int16 zone x, int16 zone z,
    ///     65×65 float32 heights, 65×65 uint16 biomes, 65×65 RGBA8 masks,
    ///     65×65 float32 forest factors (what decides forest grass and shrubs),
    ///   rows running south to north, samples west to east, 1 m apart, starting at the
    ///   zone's south-west corner.
    /// </summary>
    [BepInPlugin("io.github.dmshm.munin.exporter", "Munin Exporter", "0.1.0")]
    public class Plugin : BaseUnityPlugin
    {
        const int ZoneSize = 64;
        const int Side = ZoneSize + 1;

        static string Root => Path.Combine(Environment.GetEnvironmentVariable("HOME") ?? ".", "Library/Application Support/Munin");

        Thread worker;
        volatile int done, total;
        volatile string result;

        void Awake()
        {
            new Terminal.ConsoleCommand(
                "munin_export",
                "[radius] — write the generated terrain of every explored zone (or of zones within radius m of you) for Munin",
                args => Export(args));
            Logger.LogInfo("munin_export ready");
        }

        void Export(Terminal.ConsoleEventArgs args)
        {
            if (worker != null && worker.IsAlive) { args.Context.AddString($"munin_export: still running, {done}/{total} zones"); return; }
            var generator = WorldGenerator.instance;
            if (generator == null) { args.Context.AddString("munin_export: join a world first"); return; }

            var zones = ZonesToExport(args.Args.Length > 1 && float.TryParse(args.Args[1], out var r) ? r : (float?)null, out var source);
            var world = ZNet.instance != null ? ZNet.instance.GetWorldName() : "world";
            var path = Path.Combine(Root, "terrain", Sanitize(world) + ".terrain");
            done = 0;
            total = zones.Count;
            result = null;
            args.Context.AddString($"munin_export: {zones.Count} zones ({source}) → {path}");

            worker = new Thread(() =>
            {
                try
                {
                    Write(generator, zones, path);
                    result = $"munin_export: done, {zones.Count} zones written to {path}";
                }
                catch (Exception e)
                {
                    result = "munin_export failed: " + e.Message;
                }
            }) { IsBackground = true, Name = "munin_export" };
            worker.Start();
        }

        int lastReported = -1;

        void Update()
        {
            if (result != null)
            {
                Logger.LogInfo(result);
                Console.instance?.Print(result);
                result = null;
                lastReported = -1;
            }
            else if (worker != null && worker.IsAlive && total > 0)
            {
                int pct = done * 100 / total;
                if (pct / 10 != lastReported) { lastReported = pct / 10; Console.instance?.Print($"munin_export: {pct}%"); }
            }
        }

        /// <summary>Explored zones as listed by the app (export/zones.txt, "x z" per line),
        /// or zones within a radius of the player when a radius is given or there is no list.</summary>
        static List<Vector2i> ZonesToExport(float? radius, out string source)
        {
            var list = new List<Vector2i>();
            var file = Path.Combine(Root, "export", "zones.txt");
            if (radius == null && File.Exists(file))
            {
                foreach (var line in File.ReadAllLines(file))
                {
                    var parts = line.Split(new[] { ' ', '\t', ',' }, StringSplitOptions.RemoveEmptyEntries);
                    if (parts.Length == 2 && int.TryParse(parts[0], out var x) && int.TryParse(parts[1], out var z)) list.Add(new Vector2i(x, z));
                }
                source = "explored, from zones.txt";
                return list;
            }
            var r = radius ?? 1000;
            var center = Player.m_localPlayer != null ? Player.m_localPlayer.transform.position : Vector3.zero;
            int cx = Mathf.RoundToInt(center.x / ZoneSize), cz = Mathf.RoundToInt(center.z / ZoneSize), n = Mathf.CeilToInt(r / ZoneSize);
            for (int z = cz - n; z <= cz + n; z++)
                for (int x = cx - n; x <= cx + n; x++)
                    if (new Vector2((x - cx) * ZoneSize, (z - cz) * ZoneSize).magnitude <= r) list.Add(new Vector2i(x, z));
            source = $"within {r:0} m of you";
            return list;
        }

        void Write(WorldGenerator generator, List<Vector2i> zones, string path)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            var tmp = path + ".part";
            using (var w = new BinaryWriter(File.Create(tmp)))
            {
                w.Write(new[] { (byte)'M', (byte)'U', (byte)'N', (byte)'T' });
                w.Write(2);
                w.Write(ZoneSize);
                w.Write(Side);
                w.Write(zones.Count);
                var heights = new float[Side * Side];
                var biomes = new ushort[Side * Side];
                var masks = new byte[Side * Side * 4];
                var forest = new float[Side * Side];
                foreach (var zone in zones)
                {
                    float x0 = zone.x * ZoneSize - ZoneSize / 2f, z0 = zone.y * ZoneSize - ZoneSize / 2f;
                    for (int row = 0; row < Side; row++)
                    {
                        for (int col = 0; col < Side; col++)
                        {
                            float wx = x0 + col, wz = z0 + row;
                            var biome = generator.GetBiome(wx, wz);
                            int i = row * Side + col;
                            heights[i] = generator.GetBiomeHeight(biome, wx, wz, out Color mask);
                            biomes[i] = (ushort)biome;
                            masks[i * 4] = (byte)(Mathf.Clamp01(mask.r) * 255);
                            masks[i * 4 + 1] = (byte)(Mathf.Clamp01(mask.g) * 255);
                            masks[i * 4 + 2] = (byte)(Mathf.Clamp01(mask.b) * 255);
                            masks[i * 4 + 3] = (byte)(Mathf.Clamp01(mask.a) * 255);
                            forest[i] = WorldGenerator.GetForestFactor(new Vector3(wx, 0, wz));
                        }
                    }
                    w.Write((short)zone.x);
                    w.Write((short)zone.y);
                    foreach (var h in heights) w.Write(h);
                    foreach (var b in biomes) w.Write(b);
                    w.Write(masks);
                    foreach (var f in forest) w.Write(f);
                    done++;
                }
            }
            if (File.Exists(path)) File.Delete(path);
            File.Move(tmp, path);
        }

        static string Sanitize(string name)
        {
            foreach (var c in Path.GetInvalidFileNameChars()) name = name.Replace(c, '_');
            return string.IsNullOrEmpty(name) ? "world" : name;
        }
    }
}
