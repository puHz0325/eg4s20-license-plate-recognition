"""Independent Pillow layout oracle for the diagnostic OSD, using its glyph data."""
import json,sys
from pathlib import Path
from PIL import Image,ImageDraw
CAR=Path(__file__).resolve().parents[2];sys.path.insert(0,str(CAR))
from lpr_common import CHARS

def main():
 out=CAR.parent/'tmp/osd_validation';out.mkdir(parents=True,exist_ok=True)
 glyphs=json.loads((CAR/'PL/data/osd_font.json').read_text(encoding='utf-8'))['glyphs']
 rows=[int(v,16) for t in range(4) for v in (CAR/f'PL/data/osd_font{t}.hex').read_text().split()]
 cases=[dict(status=0,raw='',length=0,votes=0,valid=0,confirmed=0,plate='',fault=0,retries=0),
  dict(status=5,raw='浙0',length=2,votes=0,valid=0,confirmed=0,plate='',fault=0,retries=0),
  dict(status=6,raw='京N8P8F8',length=7,votes=3,valid=1,confirmed=0,plate='',fault=0,retries=0),
  dict(status=7,raw='京N8P8F8',length=7,votes=4,valid=1,confirmed=1,plate='京N8P8F8',fault=0,retries=0),
  dict(status=1,raw='',length=0,votes=0,valid=0,confirmed=0,plate='',fault=3,retries=2),
  dict(status=9,raw='IO0N8F8',length=23,votes=0,valid=0,confirmed=0,plate='',fault=0,retries=0)]
 messages=['初始化','相机故障','存储等待','无有效帧','等待结果','候选无效','待确认','已确认','结果超时','推理故障']
 payloads=[]
 for number,case in enumerate(cases):
  image=Image.new('RGB',(640,480),(0x45,0x67,0x89));ImageDraw.Draw(image).rectangle((16,16,623,183),fill=(16,32,48))
  def text(value,x,y,color='white'):
   for offset,char in enumerate(value):
    mask=Image.new('1',(16,16));index=glyphs.index(char)
    mask.putdata([bool(rows[index*16+yy]&(1<<(15-xx))) for yy in range(16) for xx in range(16)])
    image.paste(color,(x+offset*32,y),mask.resize((32,32),Image.Resampling.NEAREST))
  text('确认',32,24);text(case['plate'] if case['confirmed'] else '-'*7,96,24,'#60ff90' if case['confirmed'] else '#a0a0a0')
  text(messages[case['status']].ljust(7),32,64,'#60ff90' if case['status']==7 else '#ff7070' if case['status'] in (1,9) else '#ffd060')
  text('原始',32,104);text(case['raw'].ljust(7),96,104,'#ffd060' if case['valid'] else '#ffb080')
  text('字数',352,104);text(f"{case['length']:02d}",416,104)
  text('票数',32,144);text(str(case['votes'])+'/4',96,144)
  text('故障',352,144);text(str(case['fault']),416,144)
  text('重试',480,144);text(str(case['retries']),544,144)
  image.save(out/f'expected{number}.png')
  pixels=image.tobytes()
  (out/f'expected{number}.hex').write_text(''.join(f'{(pixels[i]<<16)|(pixels[i+1]<<8)|pixels[i+2]:06x}\n' for i in range(0,len(pixels),3)))
  packed=lambda s:sum(CHARS.index(c)<<(i*7) for i,c in enumerate(s[:7]))
  payload=packed(case['plate']) | (case['confirmed']<<49) | (packed(case['raw'])<<50) | (case['length']<<99) | (case['votes']<<104) | (case['status']<<107) | (case['fault']<<111) | (case['retries']<<115) | (case['valid']<<117)
  payloads.append(f'{payload:032x}\n')
 (out/'cases.hex').write_text(''.join(payloads));(out/'cases.json').write_text(json.dumps(cases,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
 print('PASS exported six independent full-VGA OSD reference frames')
if __name__=='__main__':main()
