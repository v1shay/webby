use image::RgbaImage;
const FADE_HAZE_SIDE: u32 = 256;
#[derive(Clone, Copy, PartialEq)]
enum Effect { None, Dither, Ascii, Halftone, Scanlines, GradientBlur }
include!("effects.rs");

// Input and output are straight RGBA, max 2048 px per side. No pointers retained.
// fade: 0 none; 1 down (Code); 2 up; 3 left; 4 right; 5 edges; 6 center.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn webby_code_background(
    data: *mut u8, width: u32, height: u32, effect: u32, fade: u32,
    start: f32, end: f32, soften: bool, empty: bool,
) -> bool {
    if data.is_null() || width == 0 || height == 0 || width > 2048 || height > 2048
        || !start.is_finite() || !end.is_finite() { return false; }
    let bytes = unsafe { std::slice::from_raw_parts_mut(data, width as usize * height as usize * 4) };
    let source = RgbaImage::from_raw(width, height, bytes.to_vec()).unwrap();
    let selected = match effect {1=>Effect::Dither,2=>Effect::Ascii,3=>Effect::Halftone,4=>Effect::Scanlines,5=>Effect::GradientBlur,_=>Effect::None};
    let result = effects(&source, selected, empty);
    // Haze caps its effect raster at 1024 in Code. Restore caller dimensions for ABI.
    let mut result = if result.dimensions() != (width,height) {
        image::imageops::resize(&result,width,height,image::imageops::FilterType::Triangle)
    } else { result };
    if fade != 0 {
        let haze = soften.then(|| fade_haze(&result));
        let lastx=width.saturating_sub(1).max(1) as f32;
        let lasty=height.saturating_sub(1).max(1) as f32;
        let a=start.clamp(0.,0.99); let b=end.clamp(a+0.001,1.);
        for (x,y,pixel) in result.enumerate_pixels_mut() {
            let nx=x as f32/lastx; let ny=y as f32/lasty;
            let pos=match fade {2=>1.-ny,3=>1.-nx,4=>nx,5=>((nx-0.5).abs().max((ny-0.5).abs())*2.).clamp(0.,1.),6=>1.-((nx-0.5).abs().max((ny-0.5).abs())*2.).clamp(0.,1.),_=>ny};
            // Exact Code top-to-bottom default; configurable span uses same curve.
            let alpha=if a==0. && (b-0.92).abs()<0.0001 && empty {wallpaper_alpha(pos,true)}
                else {smootherstep((b-pos)/(b-a))};
            let blend=smootherstep((pos-0.18)/0.66);
            if let Some(ref haze)=haze {
                let soft=sample_haze(haze,nx*(haze.width()-1) as f32,ny*(haze.height()-1) as f32);
                for c in 0..3 {pixel[c]=(pixel[c] as f32*(1.-blend)+soft[c]*blend).round() as u8;}
            }
            pixel[3]=(pixel[3] as f32*alpha).round() as u8;
        }
    }
    bytes.copy_from_slice(result.as_raw()); true
}
#[cfg(test)] mod tests {
    use super::*;
    #[test] fn all_effects_and_fades_are_bounded_and_monotonic() {
        for effect in 0..6 {for fade in 0..7 {
            let mut data=vec![128u8;64*64*4]; for p in data.chunks_exact_mut(4){p[3]=255;}
            assert!(unsafe{webby_code_background(data.as_mut_ptr(),64,64,effect,fade,0.,0.92,true,true)});
            if fade==1 {assert_eq!(data[3],255);assert_eq!(data[data.len()-1],0);
                for y in 1..64 {assert!(data[y*64*4+3]<=data[(y-1)*64*4+3]);}}
        }}
    }
    #[test] fn original_dither_fixture() {
        let source=RgbaImage::from_pixel(8,8,image::Rgba([128,128,128,255]));
        let output=effects(&source,Effect::Dither,true);
        assert_eq!(output.get_pixel(0,0).0,[255,255,255,255]);
        assert_eq!(output.get_pixel(2,0).0,[10,10,10,255]);
    }
}
