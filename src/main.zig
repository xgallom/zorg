//!
//! The zengine main executable
//!

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");

const zengine = @import("zengine");
const Zengine = zengine.Zengine;
const allocators = zengine.allocators;
const ecs = zengine.ecs;
const Event = zengine.Event;
const gfx = zengine.gfx;
const Scene = zengine.gfx.Scene;
const global = zengine.global;
const math = zengine.math;
const perf = zengine.perf;
const c = zengine.ext.c;
const scheduler = zengine.scheduler;
const time = zengine.time;
const Engine = zengine.Engine;
const ui = zengine.ui;

const log = std.log.scoped(.main);

pub const std_options: std.Options = .{
    .log_level = .info,
    .log_scope_levels = &.{
        // .{ .scope = .alloc, .level = .debug },
        // .{ .scope = .engine, .level = .debug },
        // .{ .scope = .gfx_mesh, .level = .debug },
        // .{ .scope = .gfx_obj_loader, .level = .debug },
        // .{ .scope = .gfx_renderer, .level = .debug },
        // .{ .scope = .gfx_shader, .level = .debug },
        // .{ .scope = .gfx_shader_loader, .level = .debug },
        // .{ .scope = .gfx_loader, .level = .debug },
        // .{ .scope = .key_tree, .level = .debug },
        // .{ .scope = .radix_tree, .level = .debug },
        // .{ .scope = .scheduler, .level = .debug },
        // .{ .scope = .gfx_shader_loader, .level = .debug },
        // .{ .scope = .tree, .level = .debug },
        // .{ .scope = .scene, .level = .debug },
    },
    .logFn = logFn,
};

pub const zengine_options: zengine.Options = .{
    .has_debug_ui = true,
    .log_allocations = false,
    .gfx = .{
        .enable_normal_smoothing = true,
        .normal_smoothing_angle_limit = 89.9,
    },
};

const Config = struct {
    mouse_speed: f32 = 0.25,
    speed_scale: f32 = 1,
    flags: packed struct {
        mouse_captured: bool = true,
        mouse_y_inverted: bool = true,
        camera_controls: CameraControlsType = .y_up,
    } = .{},

    pub const CameraControlsType = enum(u1) {
        y_up,
        y_dynamic,
    };

    pub fn propertyEditor(self: *Config) ui.Element {
        return ui.PropertyEditor(Config).init(self).element();
    }
};

var config: Config = .{};

var gfx_loader: gfx.Loader = undefined;
var flat_scene: Scene.Flattened = undefined;
var scene_map: zengine.containers.ArrayMap(Scene.Node.Id) = .empty;

var controls = zengine.controls.CameraControls{};
var debug_ui: zengine.ui.DebugUI = undefined;
var property_editor: ui.PropertyEditorWindow = undefined;
var allocs_window: zengine.ui.AllocsWindow = undefined;
var perf_window: zengine.ui.PerfWindow = undefined;
var log_window: zengine.ui.LogWindow = .invalid;

var mouse_motion: math.Point_f32 = math.point_f32.zero;
var execute_raycast: bool = false;

const rnd = struct {
    var r: std.Random.DefaultPrng = undefined;

    fn next() u64 {
        return r.next();
    }

    fn elem(offset: f32) f32 {
        return @as(f32, @floatFromInt(next() % 5_00)) + offset;
    }

    fn delta() f32 {
        return @as(f32, @floatFromInt(next() % 5_00)) / 2 - 125;
    }

    fn step(ptr: *math.Vector3, delta_s: f32) void {
        math.vector3.add(ptr, &.{ delta() * delta_s, delta() * delta_s, delta() * delta_s });
        math.vector3.clamp(ptr, &.{ -500, 0, -500 }, &.{ 500, 50, 500 });
    }

    fn vector3() math.Vector3 {
        return .{ elem(-250), elem(-250), elem(-250) };
    }
};

fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const level_txt = comptime message_level.asText();
    const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
    log_window.print(level_txt ++ prefix2 ++ format ++ "\n", args) catch |err| {
        std.log.defaultLog(.err, .default, "failed printing to log window: {t}", .{err});
    };
    std.log.defaultLog(message_level, scope, format, args);
}

pub fn main() !void {
    // memory limit 1GB, SDL allocations are not tracked
    allocators.init(1_000_000_000);
    defer allocators.deinit();

    log_window = try .init(allocators.gpa());
    defer log_window.deinit();

    var engine = try Zengine.create(.{
        .load = &load,
        .unload = &unload,
        .input = &input,
        .update = &update,
        .render = &render,
    });
    defer engine.deinit();
    return engine.run();
}

fn load(self: *const Zengine) !bool {
    rnd.r = .init(@intCast(std.time.milliTimestamp()));
    scene_map = try .init(self.scene.allocator, 128);
    var task_list = try scheduler.TaskScheduler.init(allocators.gpa());
    defer task_list.deinit();

    Zengine.sections.sub(.load).sub(.gfx).begin();

    gfx_loader = try .init(self.renderer);
    errdefer gfx_loader.deinit();
    {
        errdefer gfx_loader.cancel();

        _ = try gfx_loader.createOriginMesh();
        _ = try gfx_loader.createDefaultMaterial();
        _ = try gfx_loader.createTestingMaterial();
        _ = try gfx_loader.createDefaultTexture();

        {
            var camera_position: math.Vector3 = .{ 4, 8, 10 };
            var camera_direction: math.Vector3 = undefined;

            math.vector3.scale(&camera_position, 0.5);
            math.vector3.lookAt(&camera_direction, &camera_position, &math.vector3.zero);

            _ = try self.renderer.insertCamera("default", &.{
                .type = .perspective,
                .position = camera_position,
                .direction = camera_direction,
            });
        }

        _ = try gfx_loader.loadLights("scene.lgh");
        _ = try gfx_loader.createLightsBuffer(null);
        _ = try gfx_loader.loadLut("lut/basic.cube");
        try gfx_loader.commit();
    }

    Zengine.sections.sub(.load).sub(.gfx).end();
    Zengine.sections.sub(.load).sub(.scene).begin();

    _ = try self.scene.createRootNode("Ambient Light", .light("Ambient"), &.{});
    Zengine.sections.sub(.load).sub(.scene).end();
    Zengine.sections.sub(.load).sub(.ui).begin();

    debug_ui = .init();
    property_editor = .init(allocators.global());
    allocs_window = .init();
    perf_window = .init(allocators.global());

    const gfx_node = try property_editor.appendNode(@typeName(gfx), "gfx");
    _ = try self.renderer.propertyEditorNode(&property_editor, gfx_node);
    _ = try gfx_loader.propertyEditorNode(&property_editor, gfx_node);
    _ = try self.scene.propertyEditorNode(&property_editor, gfx_node);

    _ = try propertyEditorNode(&property_editor);

    try self.engine.windows.getPtr("main").setRelativeMouseMode(config.flags.mouse_captured);

    Zengine.sections.sub(.load).sub(.ui).end();
    allocators.scratchRelease();
    return true;
}

fn unload(self: *const Zengine) void {
    scene_map.deinit(self.scene.allocator);
    gfx_loader.deinit();
    debug_ui.deinit();
    property_editor.deinit();
    allocs_window.deinit();
    perf_window.deinit();
}

fn input(self: *const Zengine) !bool {
    if (self.ui.show_ui) {
        controls.reset();
    }

    while (Event.poll()) |event| {
        if (self.ui.show_ui and c.ImGui_ImplSDL3_ProcessEvent(&event.sdl)) {
            switch (event.type) {
                .quit => return false,
                .key_down => {
                    if (event.sdl.key.repeat) break;
                    switch (event.sdl.key.key) {
                        c.SDLK_F1 => {
                            self.ui.show_ui = !self.ui.show_ui;
                            try self.engine.windows.getPtr("main")
                                .setRelativeMouseMode(!self.ui.show_ui and config.flags.mouse_captured);
                        },
                        c.SDLK_ESCAPE => {
                            self.ui.show_ui = !self.ui.show_ui;
                            try self.engine.windows.getPtr("main")
                                .setRelativeMouseMode(!self.ui.show_ui and config.flags.mouse_captured);
                        },
                        else => {},
                    }
                },
                else => {},
            }
            continue;
        }

        switch (event.type) {
            .quit => return false,
            .key_down => {
                if (event.sdl.key.repeat) break;
                switch (event.sdl.key.key) {
                    c.SDLK_Q => controls.set(if (config.flags.mouse_captured) .x_neg else .yaw_neg),
                    c.SDLK_E => controls.set(if (config.flags.mouse_captured) .x_pos else .yaw_pos),
                    c.SDLK_F => controls.set(if (config.flags.mouse_captured) .y_neg else .pitch_neg),
                    c.SDLK_R => controls.set(if (config.flags.mouse_captured) .y_pos else .pitch_pos),
                    c.SDLK_C => controls.set(.roll_neg),
                    c.SDLK_V => controls.set(.roll_pos),

                    c.SDLK_S => controls.set(.z_neg),
                    c.SDLK_W => controls.set(.z_pos),
                    c.SDLK_A => controls.set(.x_neg),
                    c.SDLK_D => controls.set(.x_pos),
                    c.SDLK_X => controls.set(.y_neg),
                    c.SDLK_SPACE => controls.set(.y_pos),

                    c.SDLK_K => controls.set(.scale_neg),
                    c.SDLK_L => controls.set(.scale_pos),

                    c.SDLK_LEFTBRACKET => controls.set(.custom(0)),
                    c.SDLK_RIGHTBRACKET => controls.set(.custom(1)),
                    c.SDLK_EQUALS => controls.set(.custom(2)),

                    c.SDLK_F1 => {
                        self.ui.show_ui = !self.ui.show_ui;
                        try self.engine.windows.getPtr("main")
                            .setRelativeMouseMode(!self.ui.show_ui and config.flags.mouse_captured);
                    },
                    c.SDLK_F2 => {
                        config.flags.mouse_captured = !config.flags.mouse_captured;
                        try self.engine.windows.getPtr("main")
                            .setRelativeMouseMode(config.flags.mouse_captured);
                    },
                    c.SDLK_ESCAPE => return false,
                    else => {},
                }
            },
            .key_up => {
                switch (event.sdl.key.key) {
                    c.SDLK_Q => controls.clear(if (config.flags.mouse_captured) .x_neg else .yaw_neg),
                    c.SDLK_E => controls.clear(if (config.flags.mouse_captured) .x_pos else .yaw_pos),
                    c.SDLK_F => controls.clear(if (config.flags.mouse_captured) .y_neg else .pitch_neg),
                    c.SDLK_R => controls.clear(if (config.flags.mouse_captured) .y_pos else .pitch_pos),
                    c.SDLK_C => controls.clear(.roll_neg),
                    c.SDLK_V => controls.clear(.roll_pos),

                    c.SDLK_S => controls.clear(.z_neg),
                    c.SDLK_W => controls.clear(.z_pos),
                    c.SDLK_A => controls.clear(.x_neg),
                    c.SDLK_D => controls.clear(.x_pos),
                    c.SDLK_X => controls.clear(.y_neg),
                    c.SDLK_SPACE => controls.clear(.y_pos),

                    c.SDLK_K => controls.clear(.scale_neg),
                    c.SDLK_L => controls.clear(.scale_pos),

                    c.SDLK_LEFTBRACKET => controls.clear(.custom(0)),
                    c.SDLK_RIGHTBRACKET => controls.clear(.custom(1)),
                    c.SDLK_EQUALS => controls.clear(.custom(2)),

                    else => {},
                }
            },
            .mouse_motion => {
                const main_win = self.engine.windows.getPtr("main");
                try main_win.setMousePos(
                    .{ event.sdl.motion.x, event.sdl.motion.y },
                    .{ event.sdl.motion.xrel, event.sdl.motion.yrel },
                );
                if (main_win.relativeMouseMode()) {
                    mouse_motion = .{
                        event.sdl.motion.xrel,
                        if (config.flags.mouse_y_inverted) -event.sdl.motion.yrel else event.sdl.motion.yrel,
                    };
                }
            },
            .mouse_button_down => {
                execute_raycast = true;
            },
            else => {
                log.info("{}", .{event.type});
            },
        }
    }

    return true;
}

fn update(self: *const Zengine) !bool {
    const delta = global.timeSinceLastFrame().toFloat().toValue32(.s);
    switch (config.flags.camera_controls) {
        inline else => |controls_type| updateCameraControls(self, delta, controls_type),
    }
    updateScene(self, delta);

    {
        errdefer gfx_loader.cancel();
        flat_scene = try self.scene.flatten();
        _ = try gfx_loader.createLightsBuffer(&flat_scene);
        try gfx_loader.commit();
    }

    if (execute_raycast) executeRaycast(self);

    return true;
}

fn render(self: *const Zengine) !void {
    self.ui.beginDraw();
    self.ui.drawMainMenuBar(.{
        .allocs_open = &allocs_window.is_open,
        .property_editor_open = &property_editor.is_open,
        .perf_open = &perf_window.is_open,
        .log_open = &log_window.is_open,
        .debug_ui_open = &debug_ui.is_open,
    });
    self.ui.drawDock();

    self.ui.draw(debug_ui.element(), &debug_ui.is_open);
    self.ui.draw(property_editor.element(), &property_editor.is_open);
    self.ui.draw(allocs_window.element(), &allocs_window.is_open);
    self.ui.draw(perf_window.element(), &perf_window.is_open);
    self.ui.draw(log_window.element(), &log_window.is_open);

    self.ui.endDraw();

    {
        const fa = allocators.frame();
        // self.renderer.renderScene();
        const line_pipeline = self.renderer.pipelines.graphics.get("line");
        const origin_mesh = self.renderer.mesh_bufs.getPtr("origin");
        const camera = self.renderer.cameras.getPtr("default");
        const stencil = self.renderer.textures.get("stencil");

        var command_buffer = try self.renderer.gpu_device.commandBuffer();
        errdefer command_buffer.cancel() catch unreachable;

        const swapchain = try command_buffer.swapchainTexture(self.renderer.window);
        if (!swapchain.isValid()) {
            return;
        }

        const tr_projection = try fa.create(math.Matrix4x4);
        const tr_view = try fa.create(math.Matrix4x4);
        const tr_view_projection = try fa.create(math.Matrix4x4);

        const win_size = self.renderer.window.pixelSize();
        camera.projection(
            tr_projection,
            @floatFromInt(win_size[0]),
            @floatFromInt(win_size[1]),
            0.1,
            10_000.0,
        );
        camera.transform(tr_view);
        math.matrix4x4.dot(tr_view_projection, tr_projection, tr_view);

        log.debug("camera_position: {any}", .{camera.position});
        log.debug("camera_direction: {any}", .{camera.direction});

        var render_pass = try command_buffer.renderPass(&.{
            .{ .texture = swapchain, .load_op = .clear, .store_op = .store },
        }, &.{ .texture = stencil, .clear_depth = 1, .load_op = .clear, .store_op = .store });

        render_pass.bindPipeline(line_pipeline);
        try render_pass.bindVertexBuffers(0, &.{
            .{ .buffer = origin_mesh.gpu_bufs.get(.vertex), .offset = 0 },
        });
        render_pass.bindIndexBuffer(
            &.{ .buffer = origin_mesh.gpu_bufs.get(.index), .offset = 0 },
            .@"32bit",
        );

        const uniform_buf = try fa.alloc(f32, 32);
        @memcpy(uniform_buf[0..16], math.matrix4x4.sliceConst(tr_view_projection));
        @memcpy(uniform_buf[16..32], math.matrix4x4.sliceConst(&math.matrix4x4.identity));
        command_buffer.pushUniformData(.vertex, 0, uniform_buf);

        command_buffer.pushUniformData(.fragment, 0, &math.RGBAf32{ 1, 0, 0, 1 });
        render_pass.drawIndexedPrimitives(2, 1, 0, 0, 0);

        command_buffer.pushUniformData(.fragment, 0, &math.RGBAf32{ 0, 1, 0, 1 });
        render_pass.drawIndexedPrimitives(2, 1, 2, 0, 0);

        command_buffer.pushUniformData(.fragment, 0, &math.RGBAf32{ 0, 0, 1, 1 });
        render_pass.drawIndexedPrimitives(2, 1, 4, 0, 0);

        render_pass.end();
        try command_buffer.submit();
    }
    // var items: gfx.Renderer.Items = .init(&flat_scene);
    // _ = try flat_scene.render(self.ui, &items);
}

fn executeRaycast(self: *const Zengine) void {
    execute_raycast = false;
    const camera = self.scene.renderer.activeCamera();

    const s = flat_scene.mesh_objs.slice();
    for (0..s.len) |n| {
        const obj: *const gfx.mesh.Object = s.items(.target)[n];
        const obj_key: []const u8 = s.items(.key)[n];
        const mesh_buf = obj.mesh_bufs.get(.mesh);
        const tr: *const math.Matrix4x4 = &s.items(.transform)[n];
        const buf: []const math.Vertex = @ptrCast(mesh_buf.slice(.vertex));
        for (obj.sections.items, 0..) |section, section_n| {
            var mesh_n: usize = 0;
            while (mesh_n < section.len) : (mesh_n += 3) {
                const vertexes = [_]math.vertex.CMap{
                    math.vertex.cmap(&buf[section.offset + mesh_n]),
                    math.vertex.cmap(&buf[section.offset + mesh_n + 1]),
                    math.vertex.cmap(&buf[section.offset + mesh_n + 2]),
                };
                var verts: [3]math.Vector4 = undefined;
                for (0..3) |vert_n| {
                    math.matrix4x4.apply(
                        &verts[vert_n],
                        tr,
                        &math.vector4.makeTranslatable(vertexes[vert_n].getPtrConst(.position).*),
                    );
                }
                const tri: [3]*const math.Vector3 = .{
                    verts[0][0..3],
                    verts[1][0..3],
                    verts[2][0..3],
                };
                const int_opt = math.vector3.rayIntersectTri(tri, &camera.position, &camera.direction);
                if (int_opt) |int| {
                    log.info("{s}[{}]: {}", .{ obj_key, section_n, @divExact(mesh_n, 3) });
                    log.info("verts: {any}", .{verts});
                    log.info("intersect point: {any}", .{int});
                }
            }
        }
    }
}

fn updateScene(self: *const Zengine, delta: f32) void {
    _ = self;
    _ = delta;
}

fn updateCameraControls(
    self: *const Zengine,
    delta: f32,
    comptime controls_type: Config.CameraControlsType,
) void {
    const camera = self.renderer.cameras.getPtr(self.renderer.settings.camera);
    var coords: math.vector3.Coords = undefined;
    camera.coords(&coords);

    const rotation_speed = delta / 2;
    const translation_speed = 20 * delta * config.speed_scale;
    const scale_speed = 15 * delta;

    camera.up = switch (comptime controls_type) {
        .y_up => global.cameraUp(),
        .y_dynamic => coords.y,
    };

    if (mouse_motion[0] != 0) {
        math.vector3.rotateDirectionScale(
            &camera.direction,
            &coords.x,
            rotation_speed * config.mouse_speed * mouse_motion[0],
        );
        mouse_motion[0] = 0;
    }
    if (mouse_motion[1] != 0) {
        math.vector3.rotateDirectionScale(
            &camera.direction,
            &coords.y,
            rotation_speed * config.mouse_speed * mouse_motion[1],
        );
        mouse_motion[1] = 0;
    }

    if (controls.has(.yaw_neg))
        math.vector3.rotateDirectionScale(&camera.direction, &coords.x, -rotation_speed);
    if (controls.has(.yaw_pos))
        math.vector3.rotateDirectionScale(&camera.direction, &coords.x, rotation_speed);

    if (controls.has(.pitch_neg))
        math.vector3.rotateDirectionScale(&camera.direction, &coords.y, -rotation_speed);
    if (controls.has(.pitch_pos))
        math.vector3.rotateDirectionScale(&camera.direction, &coords.y, rotation_speed);

    if (comptime controls_type == .y_dynamic) {
        if (controls.has(.roll_neg))
            math.vector3.rotateDirectionScale(&camera.up, &coords.x, -rotation_speed);
        if (controls.has(.roll_pos))
            math.vector3.rotateDirectionScale(&camera.up, &coords.x, rotation_speed);
    }

    if (controls.has(.x_neg))
        math.vector3.translateScale(&camera.position, &coords.x, -translation_speed);
    if (controls.has(.x_pos))
        math.vector3.translateScale(&camera.position, &coords.x, translation_speed);

    if (controls.has(.y_neg))
        math.vector3.translateScale(&camera.position, &coords.y, -translation_speed);
    if (controls.has(.y_pos))
        math.vector3.translateScale(&camera.position, &coords.y, translation_speed);

    if (controls.has(.z_neg))
        math.vector3.translateDirectionScale(&camera.position, &coords.z, -translation_speed);
    if (controls.has(.z_pos))
        math.vector3.translateDirectionScale(&camera.position, &coords.z, translation_speed);

    {
        const scale = switch (camera.type) {
            .ortographic => &camera.orto_scale,
            .perspective => &camera.fov,
        };

        if (controls.has(.scale_neg))
            scale.* -= scale_speed;
        if (controls.has(.scale_pos))
            scale.* += scale_speed;
    }

    if (controls.has(.custom(0)))
        config.speed_scale -= 5 * delta;
    if (controls.has(.custom(1)))
        config.speed_scale += 5 * delta;

    if (controls.has(.custom(2))) {
        camera.type = switch (camera.type) {
            .ortographic => .perspective,
            .perspective => .ortographic,
        };
        controls.clear(.custom(2));
    }

    math.vector3.normalize(&camera.direction);
    math.vector3.normalize(&camera.up);
    camera.orto_scale = std.math.clamp(
        camera.orto_scale,
        gfx.Camera.orto_scale_min,
        gfx.Camera.orto_scale_max,
    );
    camera.fov = std.math.clamp(
        camera.fov,
        gfx.Camera.fov_min,
        gfx.Camera.fov_max,
    );
}

fn propertyEditorNode(editor: *ui.PropertyEditorWindow) !*ui.PropertyEditorWindow.Item {
    const root_id = @typeName(@This());
    const root_node = try editor.appendNode(root_id, "main");

    _ = try editor.appendChild(root_node, config.propertyEditor(), root_id ++ ".config", "Config");

    return root_node;
}
