// Verbatim Code functions; see NOTICE.md and upstream/background.rs.
fn resize(pixels: &RgbaImage, side: u32) -> RgbaImage {
    let (w, h) = pixels.dimensions();
    if w <= side && h <= side {
        return pixels.clone();
    }
    let scale = (side as f64 / w as f64).min(side as f64 / h as f64);
    image::imageops::resize(
        pixels,
        (w as f64 * scale).round().max(1.) as u32,
        (h as f64 * scale).round().max(1.) as u32,
        image::imageops::FilterType::Triangle,
    )
}

fn wallpaper_alpha(position: f32, empty: bool) -> f32 {
    // A long, continuous tail: zero slope/curvature at both ends avoids the
    // visible seams of a piecewise-linear mask, including in occupied chats.
    smootherstep((1. - position) / if empty { 0.92 } else { 0.96 })
}

fn smootherstep(t: f32) -> f32 {
    let t = f64::from(t.clamp(0., 1.));
    (t * t * t * (t * (t * 6. - 15.) + 10.)) as f32
}

fn fade_haze(source: &RgbaImage) -> image::Rgba32FImage {
    // One small worker-side raster, regardless of source size. Premultiplying
    // before filtering prevents transparent artwork from acquiring dark halos.
    if source.width() == 0 || source.height() == 0 {
        return image::Rgba32FImage::new(1, 1);
    }
    let scale = (FADE_HAZE_SIDE as f32 / source.width().max(source.height()).max(1) as f32).min(1.);
    let width = (source.width() as f32 * scale).round().max(1.) as u32;
    let height = (source.height() as f32 * scale).round().max(1.) as u32;
    let small = image::Rgba32FImage::from_fn(width, height, |x, y| {
        let left = x * source.width() / width;
        let right = ((x + 1) * source.width() / width).max(left + 1);
        let top = y * source.height() / height;
        let bottom = ((y + 1) * source.height() / height).max(top + 1);
        let mut rgba = [0.; 4];
        for row in top..bottom {
            for col in left..right {
                let pixel = source.get_pixel(col, row);
                for channel in 0..3 {
                    rgba[channel] += pixel[channel] as f32 * pixel[3] as f32 / 255.;
                }
                rgba[3] += pixel[3] as f32;
            }
        }
        let count = ((right - left) * (bottom - top)) as f32;
        image::Rgba(rgba.map(|value| value / count))
    });
    image::imageops::blur(&small, 3.5)
}

fn sample_haze(image: &image::Rgba32FImage, x: f32, y: f32) -> [f32; 3] {
    let left = x.floor() as u32;
    let top = y.floor() as u32;
    let right = (left + 1).min(image.width() - 1);
    let bottom = (top + 1).min(image.height() - 1);
    let dx = x - left as f32;
    let dy = y - top as f32;
    let corners = [
        (image.get_pixel(left, top), (1. - dx) * (1. - dy)),
        (image.get_pixel(right, top), dx * (1. - dy)),
        (image.get_pixel(left, bottom), (1. - dx) * dy),
        (image.get_pixel(right, bottom), dx * dy),
    ];
    let mut rgba = [0.; 4];
    for (pixel, weight) in corners {
        for channel in 0..4 {
            rgba[channel] += pixel[channel] * weight;
        }
    }
    if rgba[3] <= 0. {
        return [0.; 3];
    }
    std::array::from_fn(|channel| (rgba[channel] * 255. / rgba[3]).min(255.))
}

fn effects(source: &RgbaImage, effect: Effect, empty: bool) -> RgbaImage {
    if effect == Effect::GradientBlur {
        return haze(source, empty);
    }
    let (w, h) = source.dimensions();
    let mut output = source.clone();
    let index = |x: u32, y: u32| -> usize { ((y.min(h - 1) * w + x.min(w - 1)) * 4) as usize };
    let pixels = source.as_raw();
    let luma = |at: usize| -> f32 {
        (pixels[at] as f32 * 0.2126
            + pixels[at + 1] as f32 * 0.7152
            + pixels[at + 2] as f32 * 0.0722)
            .round()
    };
    match effect {
        Effect::None => {}
        Effect::Dither => {
            let bayer = [
                [0., 8., 2., 10.],
                [12., 4., 14., 6.],
                [3., 11., 1., 9.],
                [15., 7., 13., 5.],
            ];
            for y in (0..h).step_by(2) {
                for x in (0..w).step_by(2) {
                    let at = index(x + 1, y + 1);
                    let peak = pixels[at..at + 3].iter().max().copied().unwrap_or(0) as f32;
                    let gain = if peak / 255.
                        > (bayer[((y / 2) % 4) as usize][((x / 2) % 4) as usize] + 0.5) / 16.
                    {
                        255. / peak.max(1.)
                    } else {
                        0.08
                    };
                    let color = image::Rgba([
                        (pixels[at] as f32 * gain).round() as u8,
                        (pixels[at + 1] as f32 * gain).round() as u8,
                        (pixels[at + 2] as f32 * gain).round() as u8,
                        pixels[at + 3],
                    ]);
                    for dy in 0..2.min(h - y) {
                        for dx in 0..2.min(w - x) {
                            output.put_pixel(x + dx, y + dy, color);
                        }
                    }
                }
            }
        }
        Effect::Ascii => {
            let glyphs = [
                [0, 0, 0, 0, 0, 0, 0],
                [0, 0, 0, 0, 0, 4, 0],
                [0, 4, 0, 0, 4, 0, 0],
                [0, 0, 0, 14, 0, 0, 0],
                [0, 0, 14, 0, 14, 0, 0],
                [0, 4, 4, 31, 4, 4, 0],
                [0, 21, 14, 31, 14, 21, 0],
                [10, 10, 31, 10, 31, 10, 10],
                [17, 2, 4, 4, 8, 16, 17],
                [14, 17, 23, 21, 23, 16, 14],
            ];
            for y in 0..h {
                for x in 0..w {
                    let sample = index(x / 6 * 6 + 3, y / 8 * 8 + 4);
                    let glyph = glyphs[((luma(sample) / 255.).sqrt() * 9.).floor() as usize];
                    let ink = x % 6 < 5
                        && y % 8 < 7
                        && (glyph[(y % 8) as usize] & (1 << (4 - x % 6))) != 0;
                    let at = index(x, y);
                    let dest = output.get_pixel_mut(x, y);
                    for color in 0..3 {
                        dest[color] = (pixels[at + color] as f32 * 0.6
                            + if ink {
                                pixels[sample + color] as f32 * 0.4
                            } else {
                                0.
                            })
                        .round() as u8;
                    }
                }
            }
        }
        Effect::Halftone => {
            for y in (0..h).step_by(4) {
                for x in (0..w).step_by(4) {
                    let radius = 2. * (0.3 + 0.7 * (luma(index(x, y)) / 255.).sqrt());
                    let dot = index(x + 2, y + 2);
                    for dy in 0..4.min(h - y) {
                        for dx in 0..4.min(w - x) {
                            let distance =
                                ((dx as f32 - 1.5).powi(2) + (dy as f32 - 1.5).powi(2)).sqrt();
                            let coverage = (radius + 0.5 - distance).clamp(0., 1.)
                                * pixels[dot + 3] as f32
                                / 255.;
                            let at = index(x + dx, y + dy);
                            let dest = output.get_pixel_mut(x + dx, y + dy);
                            for color in 0..3 {
                                dest[color] = (pixels[at + color] as f32 * 0.6
                                    + pixels[dot + color] as f32 * coverage * 0.4)
                                    .round() as u8;
                            }
                        }
                    }
                }
            }
        }
        Effect::Scanlines => {
            for y in 0..h {
                if y % 3 == 0 {
                    for x in 0..w {
                        let dest = output.get_pixel_mut(x, y);
                        for color in 0..3 {
                            dest[color] = (dest[color] as f32 * 0.52).round() as u8;
                        }
                    }
                }
            }
        }
        Effect::GradientBlur => unreachable!("haze is handled before allocating output"),
    }
    output
}

fn ramp(y: f32, stops: &[(f32, f32)]) -> f32 {
    for pair in stops.windows(2) {
        if y <= pair[1].0 {
            let t = ((y - pair[0].0) / (pair[1].0 - pair[0].0)).clamp(0., 1.);
            return pair[0].1 + (pair[1].1 - pair[0].1) * t;
        }
    }
    stops.last().map(|s| s.1).unwrap_or(0.)
}

fn haze(source: &RgbaImage, empty: bool) -> RgbaImage {
    let source = resize(source, 1024);
    let soft = image::imageops::blur(&source, if empty { 7. } else { 5. });
    let strong = image::imageops::blur(&source, if empty { 18. } else { 12. });
    let mut output = source.clone();
    let (_, height) = source.dimensions();
    for (x, y, pixel) in output.enumerate_pixels_mut() {
        let p = y as f32 / height.max(1) as f32;
        let a = ramp(p, &[(0.18, 0.), (if empty { 0.60 } else { 0.70 }, 1.)]);
        let b = ramp(p, &[(if empty { 0.28 } else { 0.22 }, 0.), (0.76, 1.)]);
        let overlay = if empty {
            ramp(p, &[(0.16, 0.), (0.38, 0.26), (0.55, 0.55), (0.75, 0.78)])
        } else {
            ramp(p, &[(0.15, 0.), (0.76, 0.70)])
        };
        let scan = if y % 3 == 0 { 0.36 } else { 0. };
        let overlay = overlay + scan * (1. - overlay);
        for color in 0..3 {
            let value = source.get_pixel(x, y)[color] as f32 * (1. - a)
                + soft.get_pixel(x, y)[color] as f32 * a;
            let value = value * (1. - b) + strong.get_pixel(x, y)[color] as f32 * b;
            pixel[color] = (value * (1. - overlay) + 23. * overlay).round() as u8;
        }
        pixel[3] = source.get_pixel(x, y)[3];
    }
    output
}
