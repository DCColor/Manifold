// vtdnxprobe — can compressed DNxHR packets demuxed by LIBAV reach Apple's Avid plug-in decoder?
//
// The question this answers is NOT "can AVFoundation decode this MXF" — `mxfmeas` covers that.
// It is the narrower one the MXF decode route depends on: **do libav's `AVdh` packets decode
// through a HAND-BUILT `VTDecompressionSession`, with no AVFoundation container open anywhere in
// the path**, so that demuxing, range, captions, audio and geometry can all stay on libav while
// only the decode step moves. See `../BUGS.md` → "the narrow MXF plan is VIABLE".
//
// ⚠️ REGISTRATION IS NOT OPTIONAL AND THERE IS NO FLAG TO SKIP IT. Every phase calls
//     VTRegisterProfessionalVideoWorkflowVideoDecoders()   VideoToolbox/VTProfessionalVideoWorkflow.h
//     MTRegisterProfessionalVideoWorkflowFormatReaders()   MediaToolbox/MTProfessionalVideoWorkflow.h
// before touching VideoToolbox or AVFoundation. A run that silently forgot reports −12906
// "no decoder" and looks like a finding rather than like an omission — the error that cost the
// most time in the investigation behind this. Same warning, same reason, as `README.md`.
//
// ⚠️ THE PHASE SPLIT IS REQUIRED, NOT TIDINESS. A format description the Avid decoder does not
// like SEGFAULTS `DNXDecoder` inside `VTDecoderXPCService` (`parse_metadata` calls
// `CFDictionaryGetValue` with no null check). VideoToolbox reports that as −17696
// `kVTVideoDecoderUnknownErr`, which reads like a soft failure and is not: afterwards
// `VTDecompressionSessionInvalidate` BLOCKS FOREVER in `xpc_connection_send_message_with_reply_sync`,
// measured at seven minutes at 0 % CPU. So each attempt runs as its OWN PROCESS, `try` sets
// `alarm(60)`, and it `_exit`s rather than calling Invalidate. Merging the phases back into one
// process means one bad variant takes the whole run with it.
//
// ⚠️ It #includes the APP'S OWN CFFmpeg shim rather than a private copy, for the reason
// `build-mxfmeas.sh` states: a harness measuring a different libav measures nothing.
//
//   ref DIR is written by `ref` and read by `try` — run `ref` first.
//
//   MODE                                          what it does
//   ----------------------------------------------------------------------------------------------
//   ref  FILE SKIP DIR      libav demux -> pkt.bin (+ pkt.plist); Apple's format-description
//                           extensions -> ext.plist; AVAssetReader frame SKIP -> ref.raw.
//                           This is the ONLY phase that opens the container with AVFoundation.
//   try  DIR VARIANT PIXFMT [FILE]
//                           ONE session, ONE format-description variant, ONE pixel format.
//                           VARIANT: empty | null | plist | live | sel:<keys>|<atoms> | adhr:<hex>
//                           PIXFMT:  native | x420 | x422 | x444 | BGRA | v210
//   cmp  A.raw B.raw        plane-for-plane, in 16-bit words and 10-bit codes. Aborts on a raster
//                           or pixel-format mismatch rather than comparing two different pictures.
//   seq  FILE N ADHRHEX     N consecutive libav packets through ONE session built from a
//                           SYNTHESISED ADHR — the sustained-decode case, and the one that shows
//                           the container is not needed at all.
//
// ⚠️ `adhr:<hex>` is the point of the whole harness. A hand-built 28-byte ADHR — nothing lifted
// from the container — decodes bit-identically to AVAssetReader. That is what makes the narrow
// plan narrow, and it is the claim most worth re-checking if any of this stops reproducing.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <VideoToolbox/VTProfessionalVideoWorkflow.h>
#import <MediaToolbox/MTProfessionalVideoWorkflow.h>
#include "shim.h"   // the APP'S OWN umbrella — see the note above
#include <unistd.h>
#include <signal.h>

static void onAlarm(int s){ (void)s; const char *m = "\n  *** TIMED OUT (wedged, decoder XPC service most likely died) ***\n";
    write(2, m, strlen(m)); _exit(9); }

static uint32_t fcc(const char *s){ return (uint32_t)((s[0]<<24)|(s[1]<<16)|(s[2]<<8)|s[3]); }
static void fccstr(uint32_t v, char o[5]){ o[0]=(v>>24)&0xff;o[1]=(v>>16)&0xff;o[2]=(v>>8)&0xff;o[3]=v&0xff;o[4]=0;
    for(int i=0;i<4;i++) if(o[i]<32||o[i]>126) o[i]='?'; }

static CVPixelBufferRef g_out = NULL; static OSStatus g_cb = noErr; static int g_cbCalls = 0;
static void cb(void*a,void*b,OSStatus st,VTDecodeInfoFlags f,CVImageBufferRef img,CMTime p,CMTime d){
    (void)a;(void)b;(void)f;(void)p;(void)d; g_cbCalls++; g_cb = st;
    if (st==noErr && img){ if(g_out) CFRelease(g_out); g_out=(CVPixelBufferRef)CFRetain(img); } }

// ---- raw plane dump: magic,fourcc,W,H,nplanes,[w,h,stride,bytes...] ----------
static void writeRaw(CVPixelBufferRef pb, const char *path){
    FILE *f = fopen(path,"wb"); if(!f){ printf("  cannot write %s\n", path); return; }
    uint32_t magic=0x56545231, fmt=(uint32_t)CVPixelBufferGetPixelFormatType(pb);
    uint32_t W=(uint32_t)CVPixelBufferGetWidth(pb), H=(uint32_t)CVPixelBufferGetHeight(pb);
    uint32_t np=(uint32_t)CVPixelBufferGetPlaneCount(pb);
    fwrite(&magic,4,1,f); fwrite(&fmt,4,1,f); fwrite(&W,4,1,f); fwrite(&H,4,1,f); fwrite(&np,4,1,f);
    CVPixelBufferLockBaseAddress(pb,kCVPixelBufferLock_ReadOnly);
    if (np==0){ uint32_t w=W,h=H,s=(uint32_t)CVPixelBufferGetBytesPerRow(pb);
        fwrite(&w,4,1,f);fwrite(&h,4,1,f);fwrite(&s,4,1,f);
        fwrite(CVPixelBufferGetBaseAddress(pb),1,(size_t)s*h,f); }
    for(uint32_t p=0;p<np;p++){
        uint32_t w=(uint32_t)CVPixelBufferGetWidthOfPlane(pb,p), h=(uint32_t)CVPixelBufferGetHeightOfPlane(pb,p);
        uint32_t s=(uint32_t)CVPixelBufferGetBytesPerRowOfPlane(pb,p);
        fwrite(&w,4,1,f);fwrite(&h,4,1,f);fwrite(&s,4,1,f);
        fwrite(CVPixelBufferGetBaseAddressOfPlane(pb,p),1,(size_t)s*h,f); }
    CVPixelBufferUnlockBaseAddress(pb,kCVPixelBufferLock_ReadOnly);
    fclose(f); printf("      wrote %s\n", path);
}

static void describe(const char *tag, CVPixelBufferRef pb){
    char f[5]; fccstr((uint32_t)CVPixelBufferGetPixelFormatType(pb),f);
    printf("      %s: %zux%zu fmt='%s' planes=%zu\n",tag,CVPixelBufferGetWidth(pb),
        CVPixelBufferGetHeight(pb),f,CVPixelBufferGetPlaneCount(pb));
    CVPixelBufferLockBaseAddress(pb,kCVPixelBufferLock_ReadOnly);
    for(size_t p=0;p<CVPixelBufferGetPlaneCount(pb);p++){
        size_t w=CVPixelBufferGetWidthOfPlane(pb,p),h=CVPixelBufferGetHeightOfPlane(pb,p);
        size_t s=CVPixelBufferGetBytesPerRowOfPlane(pb,p);
        const uint8_t *bs=CVPixelBufferGetBaseAddressOfPlane(pb,p);
        uint16_t mn=0xffff,mx=0;
        for(size_t y=0;y<h;y+=4){ const uint16_t*r=(const uint16_t*)(bs+y*s);
            for(size_t x=0;x<w*(p?2:1);x+=2){ uint16_t v=r[x]; if(v<mn)mn=v; if(v>mx)mx=v; } }
        printf("        plane%zu %zux%zu stride=%zu  word range [%u..%u] = 10-bit [%u..%u]\n",
            p,w,h,s,mn,mx,mn>>6,mx>>6); }
    CVPixelBufferUnlockBaseAddress(pb,kCVPixelBufferLock_ReadOnly);
    CFDictionaryRef at=CVBufferGetAttachments(pb,kCVAttachmentMode_ShouldPropagate);
    if(at){ CFStringRef pr=CFDictionaryGetValue(at,kCVImageBufferColorPrimariesKey);
        CFStringRef tr=CFDictionaryGetValue(at,kCVImageBufferTransferFunctionKey);
        CFStringRef mx2=CFDictionaryGetValue(at,kCVImageBufferYCbCrMatrixKey);
        printf("        primaries=%s transfer=%s matrix=%s\n",
            pr?[(__bridge NSString*)pr UTF8String]:"—", tr?[(__bridge NSString*)tr UTF8String]:"—",
            mx2?[(__bridge NSString*)mx2 UTF8String]:"—"); }
}

// ============================ PHASE: ref =====================================
static int phaseRef(const char *path, int skip, const char *dir){
    printf("=== REGISTRATION ===\n");
    VTRegisterProfessionalVideoWorkflowVideoDecoders();
    MTRegisterProfessionalVideoWorkflowFormatReaders();
    printf("  VTRegisterProfessionalVideoWorkflowVideoDecoders()  called\n");
    printf("  MTRegisterProfessionalVideoWorkflowFormatReaders()  called\n");
    NSArray *b=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:
        @"/Library/Video/Professional Video Workflow Plug-Ins" error:nil];
    printf("  %lu plug-in bundles, DNXDecoder.bundle %s\n",(unsigned long)b.count,
        [b containsObject:@"DNXDecoder.bundle"]?"present":"MISSING");

    printf("\n=== libav demux (no decode) ===\n");
    AVFormatContext *fc=NULL;
    if(avformat_open_input(&fc,path,NULL,NULL)<0){printf("  libav open FAILED\n");return 1;}
    avformat_find_stream_info(fc,NULL);
    int v=-1; for(unsigned i=0;i<fc->nb_streams;i++)
        if(fc->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO){v=i;break;}
    if(v<0){printf("  no video stream\n");return 1;}
    AVCodecParameters *par=fc->streams[v]->codecpar;
    char tg[5]; fccstr((uint32_t)par->codec_tag,tg);
    AVRational tb=fc->streams[v]->time_base, fr=fc->streams[v]->avg_frame_rate;
    printf("  %dx%d codec=%s tag='%s'(0x%08x)  EXTRADATA=%d BYTES\n",par->width,par->height,
        avcodec_get_name(par->codec_id),tg,par->codec_tag,par->extradata_size);
    printf("  pix_fmt=%d bits_per_raw=%d profile=%d  tb=%d/%d fps=%d/%d\n",par->format,
        par->bits_per_raw_sample,par->profile,tb.num,tb.den,fr.num,fr.den);
    printf("  colorspace=%d primaries=%d trc=%d range=%d\n",par->color_space,
        par->color_primaries,par->color_trc,par->color_range);

    AVPacket *p=av_packet_alloc(); int idx=0; char buf[1024];
    while(av_read_frame(fc,p)>=0){
        if(p->stream_index==v){
            if(idx++<skip){av_packet_unref(p);continue;}
            snprintf(buf,sizeof buf,"%s/pkt.bin",dir);
            FILE*f=fopen(buf,"wb"); fwrite(p->data,1,p->size,f); fclose(f);
            printf("  packet[%d] %d bytes pts=%lld (%.4f s)  first8=%02x %02x %02x %02x %02x %02x %02x %02x\n",
                skip,p->size,(long long)p->pts,p->pts==AV_NOPTS_VALUE?-1:p->pts*av_q2d(tb),
                p->data[0],p->data[1],p->data[2],p->data[3],p->data[4],p->data[5],p->data[6],p->data[7]);
            printf("      wrote %s\n",buf);
            NSDictionary *m=@{@"w":@(par->width),@"h":@(par->height),
                @"tag":@((unsigned)par->codec_tag),@"pts":@((long long)(p->pts==AV_NOPTS_VALUE?0:p->pts)),
                @"tbden":@(tb.den?tb.den:24),@"frn":@(fr.num?fr.num:24),@"frd":@(fr.den?fr.den:1),
                @"size":@(p->size)};
            snprintf(buf,sizeof buf,"%s/pkt.plist",dir);
            [m writeToURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:buf]] error:nil];
            av_packet_unref(p); break; }
        av_packet_unref(p); }

    printf("\n=== AVFoundation open (Apple MXF format reader) ===\n");
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:
        [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]] options:nil];
    NSArray<AVAssetTrack*> *vt=[asset tracksWithMediaType:AVMediaTypeVideo];
    printf("  duration=%.3f s   video tracks=%lu   all tracks=%lu\n",
        CMTimeGetSeconds(asset.duration),(unsigned long)vt.count,(unsigned long)asset.tracks.count);
    if(!vt.count){ printf("  NO VIDEO TRACK — AVFoundation could not open it\n"); return 2; }
    CMFormatDescriptionRef fd=(__bridge CMFormatDescriptionRef)vt[0].formatDescriptions[0];
    CMVideoDimensions d=CMVideoFormatDescriptionGetDimensions(fd);
    char c[5]; fccstr(CMFormatDescriptionGetMediaSubType(fd),c);
    CFDictionaryRef e=CMFormatDescriptionGetExtensions(fd);
    printf("  track FD: '%s' %dx%d   extensions = %s, %ld keys\n",c,d.width,d.height,
        e?"PRESENT":"NULL", e?(long)CFDictionaryGetCount(e):-1L);
    if(e){ CFStringRef s=CFCopyDescription(e);
        printf("  --- Apple's extensions dictionary ---\n%s\n", [(__bridge NSString*)s UTF8String]);
        CFRelease(s);
        NSError *err=nil;
        NSData *pl=[NSPropertyListSerialization dataWithPropertyList:(__bridge id)e
            format:NSPropertyListBinaryFormat_v1_0 options:0 error:&err];
        snprintf(buf,sizeof buf,"%s/ext.plist",dir);
        if(pl){ [pl writeToFile:[NSString stringWithUTF8String:buf] atomically:YES];
                printf("      wrote %s (%lu bytes)\n",buf,(unsigned long)pl.length); }
        else printf("      extensions NOT plist-serialisable: %s\n", err.localizedDescription.UTF8String); }

    printf("\n=== AVAssetReader reference, x420 ===\n");
    NSError *err=nil;
    AVAssetReader *rd=[AVAssetReader assetReaderWithAsset:asset error:&err];
    AVAssetReaderTrackOutput *o=[AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:vt[0]
        outputSettings:@{(id)kCVPixelBufferPixelFormatTypeKey:
            @(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)}];
    [rd addOutput:o];
    if(![rd startReading]){ printf("  startReading FAILED: %s\n",rd.error.localizedDescription.UTF8String); return 3; }
    for(int i=0;i<=skip;i++){
        CMSampleBufferRef s=[o copyNextSampleBuffer];
        if(!s){ printf("  ran out at sample %d\n",i); break; }
        if(i==skip){ printf("  sample[%d] pts=%.4f s\n",i,
                CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(s)));
            CVPixelBufferRef ib=(CVPixelBufferRef)CMSampleBufferGetImageBuffer(s);
            if(ib){ describe("ref",ib); snprintf(buf,sizeof buf,"%s/ref.raw",dir); writeRaw(ib,buf); }
            else printf("  NO IMAGE BUFFER\n"); }
        CFRelease(s); }
    [rd cancelReading];
    printf("\n=== ref phase done ===\n");
    return 0;
}

// ============================ PHASE: try =====================================
static int phaseTry(const char *dir, const char *variant, const char *pfName, const char *path){
    alarm(60); signal(SIGALRM, onAlarm);
    VTRegisterProfessionalVideoWorkflowVideoDecoders();
    MTRegisterProfessionalVideoWorkflowFormatReaders();
    char buf[1024];
    snprintf(buf,sizeof buf,"%s/pkt.plist",dir);
    NSDictionary *m=[NSDictionary dictionaryWithContentsOfURL:
        [NSURL fileURLWithPath:[NSString stringWithUTF8String:buf]] error:nil];
    snprintf(buf,sizeof buf,"%s/pkt.bin",dir);
    NSData *pkt=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:buf]];
    if(!m||!pkt){ printf("  missing pkt.bin/pkt.plist — run the ref phase first\n"); return 1; }
    int W=[m[@"w"] intValue], H=[m[@"h"] intValue];
    uint32_t tag=[m[@"tag"] unsignedIntValue]; if(!tag) tag=fcc("AVdh");

    OSType want=0;
    if(!strcmp(pfName,"x420")) want=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    else if(!strcmp(pfName,"x422")) want=kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
    else if(!strcmp(pfName,"x444")) want=kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange;
    else if(!strcmp(pfName,"BGRA")) want=kCVPixelFormatType_32BGRA;
    else if(!strcmp(pfName,"v210")) want=kCVPixelFormatType_422YpCbCr10;
    else if(!strcmp(pfName,"native")) want=0;

    CMVideoFormatDescriptionRef fd=NULL; OSStatus st;
    char tg[5]; fccstr(tag,tg);
    printf("  variant=%-8s pixelformat=%-6s  codec='%s' %dx%d  packet=%lu bytes\n",
        variant,pfName,tg,W,H,(unsigned long)pkt.length);

    if(!strcmp(variant,"empty")){
        CFMutableDictionaryRef e=CFDictionaryCreateMutable(NULL,0,
            &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
        st=CMVideoFormatDescriptionCreate(kCFAllocatorDefault,tag,W,H,e,&fd); CFRelease(e);
        printf("  FD from stream params, EMPTY extensions dict = %d\n",(int)st);
    } else if(!strcmp(variant,"null")){
        st=CMVideoFormatDescriptionCreate(kCFAllocatorDefault,tag,W,H,NULL,&fd);
        printf("  FD from stream params, NULL extensions = %d\n",(int)st);
    } else if(!strcmp(variant,"plist")){
        snprintf(buf,sizeof buf,"%s/ext.plist",dir);
        NSData *d=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:buf]];
        if(!d){ printf("  no ext.plist\n"); return 1; }
        NSDictionary *e=[NSPropertyListSerialization propertyListWithData:d options:0 format:nil error:nil];
        st=CMVideoFormatDescriptionCreate(kCFAllocatorDefault,tag,W,H,(__bridge CFDictionaryRef)e,&fd);
        printf("  FD from stream params + Apple's extensions REBUILT from plist (%lu keys) = %d\n",
            (unsigned long)e.count,(int)st);
    } else if(!strncmp(variant,"sel:",4)){
        // sel:<top-level keys>|<atom keys>   — either side may be empty
        snprintf(buf,sizeof buf,"%s/ext.plist",dir);
        NSData *dd=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:buf]];
        if(!dd){ printf("  no ext.plist\n"); return 1; }
        NSDictionary *full=[NSPropertyListSerialization propertyListWithData:dd options:0 format:nil error:nil];
        NSString *spec=[NSString stringWithUTF8String:variant+4];
        NSArray *halves=[spec componentsSeparatedByString:@"|"];
        NSArray *tops=[halves[0] length]?[halves[0] componentsSeparatedByString:@","]:@[];
        NSArray *atoms=halves.count>1&&[halves[1] length]?[halves[1] componentsSeparatedByString:@","]:@[];
        NSMutableDictionary *e=[NSMutableDictionary dictionary];
        for(NSString *k in tops){ id v2=full[k]; if(v2) e[k]=v2; else printf("  (no such key: %s)\n",k.UTF8String); }
        if(atoms.count){
            NSDictionary *fa=full[@"SampleDescriptionExtensionAtoms"];
            NSMutableDictionary *sa=[NSMutableDictionary dictionary];
            for(NSString *k in atoms){ id v2=fa[k]; if(v2) sa[k]=v2; else printf("  (no such atom: %s)\n",k.UTF8String); }
            e[@"SampleDescriptionExtensionAtoms"]=sa; }
        st=CMVideoFormatDescriptionCreate(kCFAllocatorDefault,tag,W,H,(__bridge CFDictionaryRef)e,&fd);
        printf("  FD with SELECTED extensions {%s} atoms {%s} = %d\n",
            [[tops componentsJoinedByString:@","] UTF8String],
            [[atoms componentsJoinedByString:@","] UTF8String],(int)st);
    } else if(!strncmp(variant,"adhr:",5)){
        // adhr:<hex bytes> — a hand-built ADHR atom, nothing taken from the container
        const char *hx=variant+5; size_t n=strlen(hx)/2;
        uint8_t *raw=malloc(n);
        for(size_t i=0;i<n;i++){ unsigned b2; sscanf(hx+2*i,"%2x",&b2); raw[i]=(uint8_t)b2; }
        NSData *ad=[NSData dataWithBytes:raw length:n]; free(raw);
        NSDictionary *e=@{@"SampleDescriptionExtensionAtoms":@{@"ADHR":ad}};
        st=CMVideoFormatDescriptionCreate(kCFAllocatorDefault,tag,W,H,(__bridge CFDictionaryRef)e,&fd);
        printf("  FD with SYNTHESISED ADHR (%lu bytes: %s) = %d\n",(unsigned long)n,hx,(int)st);
    } else if(!strcmp(variant,"live")){
        AVURLAsset *a=[AVURLAsset URLAssetWithURL:
            [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]] options:nil];
        NSArray<AVAssetTrack*> *vt=[a tracksWithMediaType:AVMediaTypeVideo];
        if(!vt.count){ printf("  AVFoundation could not open %s\n",path); return 1; }
        fd=(CMVideoFormatDescriptionRef)CFRetain((__bridge CFTypeRef)vt[0].formatDescriptions[0]);
        CMVideoDimensions d2=CMVideoFormatDescriptionGetDimensions(fd);
        printf("  FD taken LIVE from the AVAsset video track: %dx%d, %ld extension keys\n",
            d2.width,d2.height,(long)CFDictionaryGetCount(CMFormatDescriptionGetExtensions(fd)));
        st=noErr;
    } else { printf("  unknown variant\n"); return 1; }
    if(st!=noErr||!fd){ printf("  no format description\n"); return 2; }

    CFMutableDictionaryRef pba=CFDictionaryCreateMutable(NULL,0,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    if(want){ int32_t v=(int32_t)want; CFNumberRef n=CFNumberCreate(NULL,kCFNumberSInt32Type,&v);
        CFDictionarySetValue(pba,kCVPixelBufferPixelFormatTypeKey,n); CFRelease(n); }
    CFDictionaryRef io=CFDictionaryCreate(NULL,NULL,NULL,0,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(pba,kCVPixelBufferIOSurfacePropertiesKey,io); CFRelease(io);

    VTDecompressionOutputCallbackRecord rec={cb,NULL}; VTDecompressionSessionRef sess=NULL;
    printf("  -> VTDecompressionSessionCreate ...\n");
    st=VTDecompressionSessionCreate(kCFAllocatorDefault,fd,NULL,pba,&rec,&sess);
    printf("  VTDecompressionSessionCreate = %d  %s\n",(int)st,
        st==noErr?"SESSION OPENED":"NO SESSION");
    if(st!=noErr) return 2;

    CMBlockBufferRef bb=NULL;
    CMBlockBufferCreateWithMemoryBlock(NULL,NULL,pkt.length,kCFAllocatorDefault,NULL,0,pkt.length,0,&bb);
    CMBlockBufferReplaceDataBytes(pkt.bytes,bb,0,pkt.length);
    CMSampleBufferRef sb=NULL; size_t sz=pkt.length;
    CMSampleTimingInfo t={CMTimeMake([m[@"frd"] intValue],[m[@"frn"] intValue]),
                          CMTimeMake([m[@"pts"] longLongValue],[m[@"tbden"] intValue]),kCMTimeInvalid};
    CMSampleBufferCreateReady(kCFAllocatorDefault,bb,fd,1,1,&t,1,&sz,&sb);
    printf("  -> VTDecompressionSessionDecodeFrame ...\n");
    st=VTDecompressionSessionDecodeFrame(sess,sb,0,NULL,NULL);
    printf("  DecodeFrame = %d\n",(int)st);
    VTDecompressionSessionWaitForAsynchronousFrames(sess);
    printf("  callback fired %d time(s), status=%d  %s\n",g_cbCalls,(int)g_cb,
        g_out?"FRAME DECODED":"no pixel buffer");
    if(g_out){ describe("out",g_out);
        snprintf(buf,sizeof buf,"%s/out_%s_%s.raw",dir,variant,pfName); writeRaw(g_out,buf); }
    alarm(0);
    _exit(g_out?0:4);   // skip Invalidate: it wedges when the XPC service has died
}

// ============================ PHASE: cmp =====================================
static uint8_t *loadRaw(const char *p, uint32_t *fmt,uint32_t*W,uint32_t*H,uint32_t*np,long*len){
    FILE*f=fopen(p,"rb"); if(!f) return NULL;
    fseek(f,0,SEEK_END); *len=ftell(f); fseek(f,0,SEEK_SET);
    uint8_t*d=malloc(*len); fread(d,1,*len,f); fclose(f);
    *fmt=*(uint32_t*)(d+4); *W=*(uint32_t*)(d+8); *H=*(uint32_t*)(d+12); *np=*(uint32_t*)(d+16);
    return d; }

static int phaseCmp(const char *pa,const char *pb){
    uint32_t fa,Wa,Ha,na,fb,Wb,Hb,nb; long la,lb;
    uint8_t *A=loadRaw(pa,&fa,&Wa,&Ha,&na,&la), *B=loadRaw(pb,&fb,&Wb,&Hb,&nb,&lb);
    if(!A||!B){ printf("  cannot load (%s=%p %s=%p)\n",pa,(void*)A,pb,(void*)B); return 1; }
    char ca[5],cb2[5]; fccstr(fa,ca); fccstr(fb,cb2);
    printf("  %s : '%s' %ux%u %u planes\n  %s : '%s' %ux%u %u planes\n",pa,ca,Wa,Ha,na,pb,cb2,Wb,Hb,nb);
    if(fa!=fb){ printf("  ABORT: pixel formats differ\n"); return 1; }
    if(Wa!=Wb||Ha!=Hb){ printf("  ABORT: raster differs — comparing two different pictures\n"); return 1; }
    size_t oa=20, ob=20; int bad=0;
    for(uint32_t p=0;p<na;p++){
        uint32_t wa=*(uint32_t*)(A+oa), ha=*(uint32_t*)(A+oa+4), sa=*(uint32_t*)(A+oa+8);
        uint32_t wb=*(uint32_t*)(B+ob), hb=*(uint32_t*)(B+ob+4), sb=*(uint32_t*)(B+ob+8);
        uint8_t *da=A+oa+12, *db=B+ob+12;
        if(wa!=wb||ha!=hb){ printf("  plane%u geometry differs\n",p); return 1; }
        size_t nw = (size_t)wa*(p?2:1);
        long maxd=0; double sum=0; long n=0,nd=0;
        for(uint32_t y=0;y<ha;y++){
            const uint16_t*ra=(const uint16_t*)(da+(size_t)y*sa);
            const uint16_t*rb=(const uint16_t*)(db+(size_t)y*sb);
            for(size_t x=0;x<nw;x++){ long d=labs((long)ra[x]-(long)rb[x]);
                if(d)nd++; if(d>maxd)maxd=d; sum+=d; n++; } }
        printf("  plane%u  max|d| = %ld words (%.2f 10-bit codes)   mean|d| = %.5f   differing = %.4f %%\n",
            p,maxd,maxd/64.0,sum/(double)n,100.0*nd/(double)n);
        if(maxd) bad=1;
        oa+=12+(size_t)sa*ha; ob+=12+(size_t)sb*hb; }
    printf("  => %s\n", bad?"DIFFERS":"BIT-IDENTICAL on every plane, every sample");
    return bad; }


// ============================ PHASE: seq =====================================
// N consecutive libav packets through ONE session built from a synthesised ADHR.
static int phaseSeq(const char *path,int N,const char *hex){
    alarm(600); signal(SIGALRM,onAlarm);
    VTRegisterProfessionalVideoWorkflowVideoDecoders();
    MTRegisterProfessionalVideoWorkflowFormatReaders();
    AVFormatContext *fc=NULL;
    if(avformat_open_input(&fc,path,NULL,NULL)<0){printf("open fail\n");return 1;}
    avformat_find_stream_info(fc,NULL);
    int v=-1; for(unsigned i=0;i<fc->nb_streams;i++)
        if(fc->streams[i]->codecpar->codec_type==AVMEDIA_TYPE_VIDEO){v=i;break;}
    AVCodecParameters *par=fc->streams[v]->codecpar;
    size_t n=strlen(hex)/2; uint8_t *raw=malloc(n);
    for(size_t i=0;i<n;i++){unsigned b;sscanf(hex+2*i,"%2x",&b);raw[i]=(uint8_t)b;}
    NSDictionary *e=@{@"SampleDescriptionExtensionAtoms":@{@"ADHR":[NSData dataWithBytes:raw length:n]}};
    CMVideoFormatDescriptionRef fd=NULL;
    OSStatus st=CMVideoFormatDescriptionCreate(kCFAllocatorDefault,fcc("AVdh"),
        par->width,par->height,(__bridge CFDictionaryRef)e,&fd);
    printf("  FD (synthesised ADHR) = %d\n",(int)st); if(st!=noErr) return 2;
    CFMutableDictionaryRef pba=CFDictionaryCreateMutable(NULL,0,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    int32_t pf=kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
    CFNumberRef nn=CFNumberCreate(NULL,kCFNumberSInt32Type,&pf);
    CFDictionarySetValue(pba,kCVPixelBufferPixelFormatTypeKey,nn); CFRelease(nn);
    CFDictionaryRef io=CFDictionaryCreate(NULL,NULL,NULL,0,
        &kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(pba,kCVPixelBufferIOSurfacePropertiesKey,io); CFRelease(io);
    VTDecompressionOutputCallbackRecord rec={cb,NULL}; VTDecompressionSessionRef sess=NULL;
    st=VTDecompressionSessionCreate(kCFAllocatorDefault,fd,NULL,pba,&rec,&sess);
    printf("  ONE VTDecompressionSessionCreate = %d\n",(int)st); if(st!=noErr) return 2;
    AVPacket *p=av_packet_alloc(); int i=0,ok=0,fail=0; double t0=CFAbsoluteTimeGetCurrent();
    AVRational tb=fc->streams[v]->time_base;
    while(i<N && av_read_frame(fc,p)>=0){
        if(p->stream_index!=v){ av_packet_unref(p); continue; }
        CMBlockBufferRef bb=NULL;
        CMBlockBufferCreateWithMemoryBlock(NULL,NULL,p->size,kCFAllocatorDefault,NULL,0,p->size,0,&bb);
        CMBlockBufferReplaceDataBytes(p->data,bb,0,p->size);
        CMSampleBufferRef sb=NULL; size_t sz=p->size;
        CMSampleTimingInfo t={CMTimeMake(1001,24000),CMTimeMake(p->pts==AV_NOPTS_VALUE?i:p->pts,tb.den),kCMTimeInvalid};
        CMSampleBufferCreateReady(kCFAllocatorDefault,bb,fd,1,1,&t,1,&sz,&sb);
        if(g_out){CFRelease(g_out);g_out=NULL;}
        st=VTDecompressionSessionDecodeFrame(sess,sb,0,NULL,NULL);
        VTDecompressionSessionWaitForAsynchronousFrames(sess);
        if(g_out&&g_cb==noErr) ok++; else { fail++;
            printf("    frame %d FAILED decode=%d cb=%d\n",i,(int)st,(int)g_cb); }
        CFRelease(sb); CFRelease(bb); av_packet_unref(p); i++; }
    double el=CFAbsoluteTimeGetCurrent()-t0;
    printf("  %d frames pushed through ONE session: %d decoded, %d failed\n",i,ok,fail);
    printf("  %.2f s total, %.1f ms/frame, %.1f fps (includes SMB read + demux)\n",
        el,1000.0*el/(i?i:1),(i?i:1)/el);
    alarm(0); _exit(fail?5:0); }

// ============================ main ===========================================
int main(int argc,char**argv){
@autoreleasepool{
    setvbuf(stdout,NULL,_IONBF,0);
    if(argc<2){ printf("usage: vtdnxprobe ref FILE SKIP DIR | try DIR VARIANT PIXFMT [FILE] | cmp A B | seq FILE N ADHRHEX\n"); return 1; }
    if(!strcmp(argv[1],"ref"))  return phaseRef(argv[2],atoi(argv[3]),argv[4]);
    if(!strcmp(argv[1],"try"))  return phaseTry(argv[2],argv[3],argv[4],argc>5?argv[5]:"");
    if(!strcmp(argv[1],"cmp"))  return phaseCmp(argv[2],argv[3]);
    if(!strcmp(argv[1],"seq"))  return phaseSeq(argv[2],atoi(argv[3]),argv[4]);
    printf("unknown phase\n"); return 1;
}}
