export const REVIEW_CATEGORY: string = '待确认';
export const TRASH_CATEGORY: string = '删除';

const DEFAULT_KEYWORDS: Map<string, string[]> = new Map<string, string[]>([
  ['重要信息', [
    '订单号', '订单编号', '订单信息', '订单详情', '订单编码', '交易单号', '支付成功',
    '实付款', '实付金额', '收货信息', '核销码', '预约成功', '取件码', '电子发票', '收据', '缴费', '截止日期', '航班'
  ]],
  ['知识', [
    '教程', '教学', '操作指南', '使用指南', '操作步骤', '步骤', '第一步', '示例', '入门', '公式', '定义',
    '解题思路', '知识点', '例题', '练习题', '因式分解', '勾股定理', '方程组', '二次函数', '解方程',
    '渐近分析', '时间复杂度', '空间复杂度', '指针运算', '递归调用', '偏导数', '泰勒展开'
  ]],
  ['不重要信息', ['限时抢购', '推广广告', '立即领取', '限时秒杀', '新人专享', '广告']],
  ['信息', ['订单号', '订单编号', '取件码', '运单号', '核销码', '支付成功', '预约成功', '电子发票']],
  ['壁纸', ['壁纸', 'wallpaper']]
]);

const ORDER_FIELDS: string[][] = [
  ['订单', '下单', '交易', '购买时间'],
  ['收货', '配送', '物流', '快递', '运单', '发货', '包裹', '送达'],
  ['实付', '应付', '付款', '支付', '退款', '优惠', '金额', '合计', '小计', '运费'],
  ['商品', '数量', '规格', '商家', '店铺', '联系客服'],
  ['已完成', '待评价', '确认收货', '交易成功', '订单完成', '再次购买', '取消订单']
];

const MATH_TERMS: string[] = [
  '函数', '方程', '不等式', '抛物线', '坐标', '图像', '解析式', '三角形', '概率', '变量',
  '数列', '导数', '因式', '平方', '分母', '分数', '周长', '面积', '定理', '求值'
];

export class CategoryRule {
  readonly name: string;
  readonly keywords: string[];
  readonly useDefaults: boolean;
  readonly description: string;

  constructor(name: string, keywords: string[], useDefaults: boolean, description: string = '') {
    this.name = name;
    this.keywords = keywords;
    this.useDefaults = useDefaults;
    this.description = description;
  }
}

export function parseCategories(input: string): CategoryRule[] {
  const rules: CategoryRule[] = [];
  const seen = new Set<string>();
  const items: string[] = [];
  for (const line of input.split('\n')) {
    const colon = descriptionStart(line);
    if (colon >= 0) {
      items.push(line);
    } else {
      items.push(...line.split(/[,，、;；]+/));
    }
  }
  for (const item of items) {
    const colon = descriptionStart(item);
    const chunks = colon >= 0 ? [item.slice(0, colon)] : item.split(/[=＝]/);
    const description = colon >= 0 ? item.slice(colon + 1).trim() : '';
    const name = chunks[0].trim();
    if (name.length === 0) {
      continue;
    }
    if (name === REVIEW_CATEGORY || name === TRASH_CATEGORY || seen.has(name)) {
      throw new Error('请使用不同的类别名称。「待确认」和「删除」由应用保留。');
    }
    if (colon >= 0 && description.length === 0) {
      throw new Error('请补上「' + name + '」的说明，或只输入类别名。');
    }
    const keywords = chunks.length > 1 ? chunks.slice(1).join('=').split(/[\/／|｜]/) :
      (description.length > 0 ? [name] : DEFAULT_KEYWORDS.get(name) ?? [name]);
    const clean = Array.from(new Set(keywords.map(keyword => normalize(keyword)).filter(keyword => keyword.length > 0)));
    if (clean.length === 0) {
      throw new Error('「' + name + '」需要至少一个可识别的关键词。');
    }
    rules.push(new CategoryRule(name, clean, chunks.length === 1, description));
    seen.add(name);
  }
  if (rules.length < 2 || rules.length > 8) {
    throw new Error('请输入 2 到 8 个类别。');
  }
  return rules;
}

export function wallpaperCategory(rules: CategoryRule[], anime: boolean): string {
  if (anime) {
    const specific = rules.find(rule => rule.useDefaults &&
      /^(动漫壁纸|动画壁纸|二次元壁纸)$/.test(rule.name));
    if (specific !== undefined) {
      return specific.name;
    }
  }
  return rules.find(rule => rule.useDefaults &&
    /^(壁纸|手机壁纸|锁屏壁纸|桌面壁纸)$/.test(rule.name))?.name ?? '';
}

function descriptionStart(line: string): number {
  const colon = line.search(/[:：]/);
  const equal = line.search(/[=＝]/);
  return equal >= 0 && colon > equal ? -1 : colon;
}

function normalize(text: string): string {
  return text.normalize('NFKC').toLowerCase().replace(/[\s\p{P}]/gu, '');
}

export function looksLikeFormulaStrip(ocrText: string): boolean {
  const text = ocrText.normalize('NFKC').replace(/\s/g, '');
  // A small number of ideographs can be stray OCR readings of fraction bars and operators.
  return text.length <= 80 && /[√∫∑]/.test(text) && !/[¥$%]|元/.test(text) &&
    (text.match(/[+×÷=]/g) ?? []).length >= 3 && (text.match(/\d/g) ?? []).length >= 4 &&
    (text.match(/[\u4e00-\u9fff]/g) ?? []).length <= 5;
}

export function matchCategory(ocrText: string, rules: CategoryRule[]): string {
  const original = ocrText.normalize('NFKC').toLowerCase();
  const text = normalize(original);
  const orderFields = ORDER_FIELDS.filter(group => group.some(field => text.includes(field))).length;
  const hasOrderContext = /订单|下单|交易|收货|配送|物流|发货|运单|实付|应付/.test(text);
  const money = /(?:¥\s*\d+|\d(?:\.\d{1,2})?\s*元|\d+\.\d{2}(?!\d))/.test(original);
  const mathTerms = MATH_TERMS.filter(term => text.includes(term)).length;
  const hasEquation = /[a-z0-9)）][\t ]*(?:[=≤≥≠]|[+−×÷^])[\t ]*[-−+]?[a-z0-9(（]|[√∠△∫∑]/.test(original);
  const hasQuestion = /已知|求出|求证|解下列|证明|若.{0,32}(则|求)|求.{0,20}(值|角|长|面积|范围)/.test(text);
  const addressFields = /街道地址|详细地址|收货地址|通讯地址/.test(text) &&
    /邮政编码|邮递区号|邮编|行政区|国家地区/.test(text);
  const weatherFields = /气温|体感温度|降水概率/.test(text) && /湿度|风力|风速|空气质量/.test(text);
  const statusFields = /额度已用完|达到使用上限|存储空间不足|操作失败|支付失败|余额不足/.test(text) &&
    /重置|恢复|剩余|用量|刷新|升级|重试|管理|释放|清理|付款方式|支付方式|充值/.test(text);
  const bankCard = /银行|bank|持卡人|cardholder/.test(text) &&
    /银行卡|一卡通|储蓄卡|借记卡|信用卡|银联|unionpay|mastercard|visa卡|debitcard|creditcard/.test(text);
  const accountField = /邮箱|电子邮件|电子信箱|手机号|电话号码|用户名称|用户名|email|phonenumber|username/.test(text);
  const passwordField = /密码|验证码|password|verificationcode/.test(text);
  const agreement = /用户协议|隐私政策|服务条款|使用条款|termsofservice|privacypolicy/.test(text);
  const accountAction = /注册|创建账号|创建账户|创建帐号|登录|登入|开通账号|signup|createanaccount|createaccount|register|signin/.test(text);
  const registration = (accountAction && ((accountField && passwordField) || (passwordField && agreement))) ||
    (accountField && /获取验证码|发送验证码|确认密码|设置密码|confirmpassword|resendcode/.test(text));
  const profileForm = /生日|出生日期|birthday|dateofbirth/.test(text) && /性别|gender/.test(text) &&
    /基本信息|个人资料|下一步|basicinformation/.test(text) &&
    /输入|填写|下一步|注册|signup|next/.test(text);
  const credentialPanel = /apikeygenerated|saveyourkey|生成api密钥|保存密钥/.test(text) &&
    /secretkey|permissions|权限|复制|copy|仅显示一次/.test(text);
  const credential = credentialPanel || /sk\s*[-‐–]\s*proj\s*[-‐–](?:\s*[a-z0-9_-]){24,}/.test(original);
  const academicField = /学号|学生编号|学年度|学期|课程名称|课程代码|课程性质|学分|绩点|studentid|semester|credits|gpa/.test(text);
  const gradeField = /成绩单|成绩查询|课程成绩|学业成绩|成绩报告|成绩明细|总评成绩|最终成绩|考试成绩|transcript|academicrecord/.test(text);
  const transcript = (academicField && gradeField) ||
    (/课程名称|课程代码|学号|studentid/.test(text) && /成绩|分数|score/.test(text) && /学分|绩点|学期|credits|gpa/.test(text));
  const timetable = /课表|课程表|考试安排|监考安排|教学安排|timetable|classschedule|examschedule/.test(text) &&
    /星期|周[一二三四五六日]|教室|教学楼|考场|节次|授课|学期|时间|classroom|period|semester/.test(text);
  const roster = /名单|名册|成员列表|人员列表|入围|录取结果|roster/.test(text) &&
    /姓名|学号|班级|编号|单位|部门|考号|studentid|department/.test(text);
  const classGrid = /星期[一二三四五六日天]|周[一二三四五六日天]/.test(text) &&
    /校区|教室|考场|[楼馆]\s*[-–－]?\s*\d{2,4}/.test(original) &&
    /\b\d{8,12}\.\d{1,3}\b|\b\d{1,2}\s*[-–—－~～]\s*\d{1,2}\s*(周|[,，、\u4e00-\u9fff])/.test(original);
  const courseGrid = /课程名称|课程代码|课程编号/.test(text) && /学分|学时/.test(text) &&
    /培养方案|培养计划|总学时|学时分配|学分小计|必修|选修/.test(text);
  const rosterGrid = /姓名/.test(text) && /学号|工号|考号|人员编号|学生编号|报名编号/.test(text) &&
    /班级|学院|单位|部门|组别|职务|序号|签到|签字/.test(text);
  const gradeColumns = ['听力', '阅读', '写作', '翻译'].filter(column => text.includes(column)).length;
  const scoreGrid = gradeColumns >= 3 && /总分|考试类别|模考成绩|成绩表/.test(text) &&
    (original.match(/\d+\s*[.,]\s*\d+/g) ?? []).length >= 3;
  const travelResults = /航班|机票|航站楼|乘机人|起飞|直飞|车次|高铁/.test(text) &&
    /中转|出发|到达|经停|直飞|筛选|时间排序/.test(text) &&
    (original.match(/\d{1,2}\s*:\s*[0-5]\d/g) ?? []).length >= 4;
  const foodNotes = /路口|门外|附近|楼层|商场/.test(text) && /烧烤|火锅|餐馆|菜馆|小馆/.test(text) &&
    /人均|排队|好吃|实惠/.test(text) && /(?:^|\n)\s*\d{1,2}\s*[.、．]/.test(original);
  const card = /会员卡|校园卡|社保卡|交通卡|准考证|证件|cardnumber/.test(text) &&
    /卡号|证号|姓名|有效期|发卡|持卡|编号|expires/.test(text);
  const examQuestion = /单选题|多选题|判断题|填空题|简答题|选择题|不定项/.test(text) &&
    /答题卡|下列|交卷|倒计时|解答|试题解析|正确答案|选出/.test(text);
  const toolArticle = /\bcodex\b|\bplaywright\b|\bgsap\b|\bcaveman\b|taste\s*skill|工具介绍|工具推荐|插件介绍/.test(original) &&
    /官方|开源|安装|用法|功能|自动化|插件|网页|介绍|示例|token|github/.test(text) &&
    /写留言|文档|示例|用法|使用|仓库|安装|插件|工作流|\breadme\b/.test(original);
  const commentProfile = /ip[属屬][地址]|(?:lv\d|\d天前).{0,16}(?:回复|点赞)/.test(text);
  const commentThread = /条回复|查看回复|展开回复|评论详情|相关回复|回复共\d+条|查看对话/.test(text);
  const commentTab = /简介.{0,10}评论|评论\d{2,}/.test(text);
  const playbackControls = /下滑松手|松手锁定|\d倍速/.test(text);
  const videoComment = text.length <= 360 && ((commentProfile && (commentTab || playbackControls)) ||
    (commentTab && playbackControls && /属地|lv\d|昨天|前天|\d天前/.test(text)));
  const serviceContext = /客服|退款|物流|报名|公告|订单|售后/.test(text);
  const commentCard = ((commentProfile && commentThread) || videoComment) && !serviceContext;
  const socialDialogue = /查看次数|浏览量/.test(text) && /@/.test(original) &&
    (/[“「『"](?:为什么|怎么|我|你|谁).{2,55}[”」』"]/.test(original) ||
      (/帮我.{0,18}吗|能不能|可以.{0,18}吗/.test(text) && /为什么不|怎么不|我不要|我也能/.test(text)));
  const socialCard = /私信|查看次数|浏览量|转发/.test(text) && /关注|分享|@/.test(original) &&
    !serviceContext && (/笑死|吐槽|绷不住|离谱|一心只想/.test(text) || socialDialogue);
  const quoteMeme = text.length >= 18 && text.length <= 90 && /[“「『"]/.test(original) &&
    /[”」』"]/.test(original) && /竟然|居然|难以想象|笑死|离谱|绷不住|谁懂/.test(text) && /我们|居然|笑死|绷不住|谁懂/.test(text);
  const stagedPost = /剧情演绎|剧情虚构|仅供娱乐/.test(text) && /留言\d+|评论\d+/.test(text) &&
    /写留言|回复/.test(text);
  const repeatedPunchline = text.length <= 220 && /编辑于.{0,8}(?:今天|昨天)|vip\d/.test(text) &&
    (text.match(/如果/g) ?? []).length >= 3 &&
    /([\u4e00-\u9fff]{4,10})[。.!?！？].{6,55}\1[。.!?！？].{6,55}\1(?:[。.!?！？]|$)/.test(original.replace(/\s/g, ''));
  const playfulSign = text.length <= 65 && /标语|横幅/.test(text) && /不是.{4,34}吗|谁.{2,22}啊/.test(text);
  const formulaLines = original.split(/\r?\n/).filter(line =>
    /[=≈≤≥∫∑√]/.test(line) && /[a-z0-9α-ω]/.test(line)).length;
  const hasMathNotation = /[∫∑√∞≈≤≥∪∩⊂⊆∈∉]|[a-z0-9]\^[0-9]/.test(original) || /[a-z0-9][²³⁴]/i.test(ocrText);
  const relationLesson = /自反闭包|对称闭包|传递闭包|等价关系|偏序关系|笛卡尔积/.test(text) &&
    (/定理|举例|定义|求证/.test(text) || hasEquation || hasMathNotation);
  const shortFormula = text.length <= 100 && !/[\u4e00-\u9fff]/.test(text) &&
    (/[√∫∑π]/.test(original) || /[=＝]/.test(original)) &&
    (original.match(/[+×÷∫∑√=]/g) ?? []).length >= 3 &&
    (original.match(/\d/g) ?? []).length >= 4 && !/[¥$%]|\b(?:total|amount)\b/.test(original);
  let bestScore = 0;
  let bestCategory = REVIEW_CATEGORY;
  for (const rule of rules) {
    let score = 0;
    const hits = rule.keywords.filter(keyword => text.includes(keyword));
    for (const keyword of hits.filter(word => !hits.some(other => other !== word && other.includes(word)))) {
      score += Math.min(keyword.length, 8);
    }
    if (rule.useDefaults && rule.description.length === 0 && (rule.name === '重要信息' || rule.name === '信息') &&
      hasOrderContext &&
      (orderFields >= 3 || (orderFields >= 2 && money))) {
      score += 4 + orderFields * 2;
    }
    if (rule.useDefaults && rule.description.length === 0 && rule.name === '信息' &&
      (addressFields || weatherFields || statusFields || bankCard || registration || transcript || timetable || roster || card)) {
      score += 5;
    }
    if (rule.useDefaults && rule.description.length === 0 && rule.name === '信息' &&
      (classGrid || courseGrid || rosterGrid || scoreGrid || travelResults || profileForm || foodNotes ||
        (toolArticle && !examQuestion && !hasQuestion))) {
      score += 9;
    }
    if (rule.useDefaults && rule.description.length === 0 && credential) {
      score += rule.name === '重要信息' ? 18 : rule.name === '信息' ? 17 : 0;
    }
    if (rule.useDefaults && rule.description.length === 0 && /^(表情包|聊天表情|梗图)$/.test(rule.name) &&
      (commentCard || quoteMeme || socialCard || stagedPost || repeatedPunchline || playfulSign)) {
      score += 9;
    }
    if (rule.useDefaults && rule.description.length === 0 && rule.name === '知识' &&
      ((mathTerms >= 2 && (hasEquation || hasQuestion)) || (hasEquation && hasQuestion) ||
        (formulaLines >= 2 && hasMathNotation) || examQuestion || relationLesson || shortFormula)) {
      score += 8 + Math.min(mathTerms, 4);
    }
    if (score > bestScore) {
      bestScore = score;
      bestCategory = rule.name;
    } else if (score > 0 && score === bestScore) {
      bestCategory = REVIEW_CATEGORY;
    }
  }
  return bestCategory;
}
