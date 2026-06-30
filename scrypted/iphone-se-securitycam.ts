const RTSP_URL = process.env.IPHONE_SECURITYCAM_RTSP_URL || 'rtsp://IPHONE_IP:8554/live';
const STATUS_URL = process.env.IPHONE_SECURITYCAM_STATUS_URL || 'http://IPHONE_IP:8080/status';
const SNAPSHOT_URL = process.env.IPHONE_SECURITYCAM_SNAPSHOT_URL || 'http://IPHONE_IP:8080/snapshot.jpg';
const STATUS_POLL_MS = 1500;

device.handleTypes(ScryptedInterface.MotionSensor);

export default class IPhoneSESecurityCam extends ScryptedDeviceBase {
  motionDetected = false;
  private statusPollTimer?: any;
  private lastStatusErrorAt = 0;

  constructor(nativeId?: string) {
    super(nativeId);
    this.info = {
      manufacturer: 'Apple',
      model: 'iPhone SE',
      firmware: 'Jailbreak SecurityCam 0.3.0',
    };
    this.startStatusPolling();
  }

  async run() {
    this.startStatusPolling();
  }

  private startStatusPolling() {
    if (this.statusPollTimer)
      return;

    this.statusPollTimer = setInterval(() => {
      this.pollStatus().catch(error => this.logStatusError(error));
    }, STATUS_POLL_MS);
    this.pollStatus().catch(error => this.logStatusError(error));
  }

  private async pollStatus() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 4000);
    try {
      const response = await fetch(STATUS_URL, {
        cache: 'no-store',
        signal: controller.signal,
      });
      if (!response.ok)
        throw new Error(`status ${response.status}`);

      const status = await response.json();
      const nextMotion = !!status.motionDetected;
      if (this.motionDetected !== nextMotion) {
        this.motionDetected = nextMotion;
        if (nextMotion)
          this.console.log('motion detected', status.motionScore);
      }
    } finally {
      clearTimeout(timeout);
    }
  }

  private logStatusError(error: any) {
    const now = Date.now();
    if (now - this.lastStatusErrorAt < 60000)
      return;
    this.lastStatusErrorAt = now;
    this.console.warn('status polling failed', error?.message || error);
  }

  async getPictureOptions() {
    return [
      {
        id: 'snapshot',
        name: 'SecurityCam Snapshot',
      },
    ];
  }

  async takePicture() {
    return mediaManager.createMediaObjectFromUrl(SNAPSHOT_URL);
  }

  async getVideoStreamOptions() {
    return [
      {
        id: 'rtsp-h264',
        name: 'RTSP H.264',
        container: 'rtsp',
        tool: 'ffmpeg',
        video: {
          codec: 'h264',
        },
        audio: null,
      },
    ];
  }

  async getVideoStream(_options?: any) {
    return mediaManager.createFFmpegMediaObject({
      url: RTSP_URL,
      container: 'rtsp',
      inputArguments: [
        '-rtsp_transport',
        'tcp',
        '-fflags',
        '+genpts',
      ],
      mediaStreamOptions: {
        id: 'rtsp-h264',
        name: 'RTSP H.264',
        container: 'rtsp',
        tool: 'ffmpeg',
        video: {
          codec: 'h264',
        },
        audio: null,
      },
    });
  }
}
