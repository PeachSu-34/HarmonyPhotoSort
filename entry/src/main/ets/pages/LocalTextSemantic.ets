import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { CategoryRule, REVIEW_CATEGORY } from './CategoryRules';
import { encodeEmbeddingPassages, encodeEmbeddingText, selectSemanticCategory } from './TextEmbeddingRules';

const TEXT_MODEL = 'photosort_text/bge-small-zh-v1.5.onnx';
const VOCABULARY = 'photosort_text/vocab.txt';
interface NativeTextRuntime {
  embed(model: ArrayBuffer, tokenIds: number[]): Promise<Float32Array>;
}
const DESCRIPTIONS: Map<string, string[]> = new Map<string, string[]>([
  ['信息', [
    '记录个人订单、物流进度、费用、发票、付款或预约状态的截图',
    '登记资料中的通信地址、邮政编码、城市和行政区，或者证件和银行卡上的标识',
    '应用通知和状态面板，显示使用额度、余额、剩余次数、重置时间和操作结果',
    '天气预报或监测面板中显示的温度、降水、湿度和风速',
    '填写邮箱、用户名、验证码和密码来创建账号的网页或应用注册表单',
    '按课程列出个人分数、学分、绩点和学期的成绩单或成绩查询页面',
    '课表或考试安排中列出日期、节次、上课地点或考场',
    '按姓名和编号登记的人员名单，以及附有身份或有效期的卡片',
    '教务系统的培养方案或课程清单，按课程代码、名称、学分和学时排列',
    '介绍软件、开发工具或人工智能插件的文章，配有功能说明、使用场景和仓库截图',
    '按出发到达时间、航班车次、中转站和票价列出多种出行方案的查询结果'
  ]],
  ['重要信息', [
    '银行卡入账、转账凭证、账单付款明细或者交易确认',
    '需要本人按时办理的通知，包括有效期、预约、报到、提交材料和证件',
    '购买记录、收货、售后、退款和寄件'
  ]],
  ['不重要信息', [
    '促销海报、店铺面向所有人的折扣优惠、限时活动、会员招募',
    '没有后续事项的寒暄闲聊、社交平台动态和娱乐问答'
  ]],
  ['知识', [
    '学习资料中解释数学原理、论证推导、解题练习和几何代数过程',
    '科普材料介绍专业术语、特点、产生原因、运作原理',
    '用方法、举例和操作说明教授技能或解释学科内容',
    '数学练习中的代数、方程、不等式和证明，使用推理确定问题答案',
    '自然地理、物理和生命科学材料，讲解大气、地质、气候和生物现象的成因',
    '计算机基础、程序设计和数据结构，介绍数据类型、存储方式和算法的原理',
    '手写的学科笔记，包含计算步骤、公式推导、定理或对知识点的解释',
    '人文历史与社会科学课程中的练习题，包含题干、选择项、解答和知识考查'
  ]],
  [REVIEW_CATEGORY, ['简短且缺少上下文的内容，无从判断用途']]
]);

export class LocalTextSemantic {
  private static runtime?: NativeTextRuntime;
  private static modelLoaded: boolean = false;
  private static vocabulary?: Promise<Map<string, number>>;
  private readonly rules: CategoryRule[];
  private references?: Promise<Map<string, Float32Array[]>>;
  private reviewHint: string = '';

  constructor(rules: CategoryRule[]) {
    this.rules = rules.filter(rule => rule.useDefaults &&
      (rule.description.length > 0 || (rule.name !== '风景' && rule.name !== '壁纸')));
  }

  shouldAnalyze(textLength: number): boolean {
    return this.rules.length > 0 && textLength >= 12;
  }

  getReviewHint(): string {
    return this.reviewHint;
  }

  async classify(context: common.UIAbilityContext, text: string): Promise<string> {
    this.reviewHint = '';
    if (this.references === undefined) {
      this.references = this.prepareReferences(context);
    }
    const references = await this.references;
    const vocabulary = await LocalTextSemantic.loadVocabulary(context);
    const embeddings: Float32Array[] = [];
    for (const tokens of encodeEmbeddingPassages(text, vocabulary)) {
      embeddings.push(await this.embedTokens(context, tokens));
    }
    const scores = new Map<string, number>();
    for (const reference of references) {
      const category = reference[0];
      const candidates = reference[1];
      let best = -1;
      for (const candidate of candidates) {
        for (const embedding of embeddings) {
          let similarity = 0;
          for (let index = 0; index < embedding.length; index++) {
            similarity += candidate[index] * embedding[index];
          }
          best = Math.max(best, similarity);
        }
      }
      scores.set(category, best);
    }
    const category = selectSemanticCategory(scores, text.replace(/\s/g, '').length >= 36);
    if (category === REVIEW_CATEGORY) {
      const options = Array.from(scores.keys()).filter(name => name !== REVIEW_CATEGORY)
        .sort((a, b) => (scores.get(b) ?? -1) - (scores.get(a) ?? -1));
      const first = options[0];
      const second = options[1];
      const best = scores.get(first) ?? -1;
      const alternative = scores.get(second) ?? -1;
      this.reviewHint = best >= 0.52 && best - alternative < 0.045 ?
        '「' + first + '」与「' + second + '」线索接近' : '文字线索不足';
    }
    return category;
  }

  private async prepareReferences(context: common.UIAbilityContext): Promise<Map<string, Float32Array[]>> {
    const references = new Map<string, Float32Array[]>();
    for (const rule of this.rules) {
      const descriptions = rule.description.length > 0 ? [rule.description] : DESCRIPTIONS.get(rule.name) ?? [rule.name];
      const embeddings: Float32Array[] = [];
      for (const description of descriptions) {
        embeddings.push(await this.embed(context, description));
      }
      references.set(rule.name, embeddings);
    }
    references.set(REVIEW_CATEGORY, [await this.embed(context, DESCRIPTIONS.get(REVIEW_CATEGORY)?.[0] ?? REVIEW_CATEGORY)]);
    return references;
  }

  private async embed(context: common.UIAbilityContext, text: string): Promise<Float32Array> {
    return this.embedTokens(context, encodeEmbeddingText(text, await LocalTextSemantic.loadVocabulary(context)));
  }

  private static loadVocabulary(context: common.UIAbilityContext): Promise<Map<string, number>> {
    if (LocalTextSemantic.vocabulary === undefined) {
      LocalTextSemantic.vocabulary = context.resourceManager.getRawFileContent(VOCABULARY)
        .then(bytes => {
          const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
          const tokens = text.split(/\r?\n/);
          const vocabulary = new Map<string, number>();
          for (let index = 0; index < tokens.length; index++) {
            if (tokens[index].length > 0) {
              vocabulary.set(tokens[index], index);
            }
          }
          return vocabulary;
        })
        .catch((error: Error) => {
          LocalTextSemantic.vocabulary = undefined;
          throw error;
        });
    }
    return LocalTextSemantic.vocabulary;
  }

  private async embedTokens(context: common.UIAbilityContext, ids: number[]): Promise<Float32Array> {
    let model = new ArrayBuffer(0);
    if (!LocalTextSemantic.modelLoaded) {
      const bytes = await context.resourceManager.getRawFileContent(TEXT_MODEL);
      model = new ArrayBuffer(bytes.length);
      new Uint8Array(model).set(bytes);
    }
    if (LocalTextSemantic.runtime === undefined) {
      LocalTextSemantic.runtime = loadNativeModule('libphotosort_ort.so') as NativeTextRuntime;
    }
    const embedding = await LocalTextSemantic.runtime.embed(model, ids);
    LocalTextSemantic.modelLoaded = true;
    let sum = 0;
    for (const value of embedding) {
      sum += value * value;
    }
    if (sum <= 0 || !Number.isFinite(sum)) {
      throw new Error('文字语义模型未返回有效结果');
    }
    const norm = Math.sqrt(sum);
    for (let index = 0; index < embedding.length; index++) {
      embedding[index] /= norm;
    }
    return embedding;
  }
}
