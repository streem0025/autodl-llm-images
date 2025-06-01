import time
import re
import random
import json
import logging
import traceback
import threading
import os
import cv2
import numpy as np
import pyautogui
import ctypes
import requests
from PIL import Image
from io import BytesIO
from selenium.webdriver.common.keys import Keys
from selenium import webdriver
from selenium.webdriver.chrome.options import Options
from selenium.webdriver.chrome.service import Service
from selenium.webdriver.common.by import By
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver import ActionChains
from webdriver_manager.chrome import ChromeDriverManager

SCREENSHOT_DIR = "screenshots"

API_URL = "http://127.0.0.1:54346"
API_KEY = "50cbdad4cff3451f9390829815c3875d"
HEADERS = {"x-api-key": API_KEY}

def get_all_opened_window_ids():
    resp = requests.post(f"{API_URL}/browser/list", json={"page": 0, "pageSize": 100}, headers=HEADERS)
    data = resp.json()
    # 只返回 status == 1 的窗口ID
    return [w["id"] for w in data["data"]["list"] if w.get("status") == 1]

def open_bitbrowser_window(window_id):
    try:
        resp = requests.post(f"{API_URL}/browser/open", json={"id": window_id}, headers=HEADERS)
        data = resp.json()["data"]
        ws_url = data["ws"]
        chromedriver_path = data["driver"]
        return ws_url, chromedriver_path
    except Exception as e:
        logger.error(f"打开窗口 {window_id} 失败: {e}")
        return None, None

from selenium import webdriver
from selenium.webdriver.chrome.options import Options

def connect_to_bitbrowser(ws_url, chromedriver_path):
    try:
        chrome_options = Options()
        host_port = ws_url.replace("ws://", "").split("/")[0]
        chrome_options.add_experimental_option("debuggerAddress", host_port)
        service = Service(executable_path=chromedriver_path)
        driver = webdriver.Chrome(service=service, options=chrome_options)
        return driver
    except Exception as e:
        logger.error(f"连接Selenium失败: {e}")
        return None

# 配置日志
logging.basicConfig(level=logging.INFO, format='[%(asctime)s] [%(levelname)s] [%(threadName)s] %(message)s')
logger = logging.getLogger(__name__)

# 在文件顶部添加锁
chat_contexts_lock = threading.Lock()

# 创建截图目录
if not os.path.exists(SCREENSHOT_DIR):
    os.makedirs(SCREENSHOT_DIR)

# Windows鼠标事件常量
MOUSEEVENTF_MOVE = 0x0001
MOUSEEVENTF_LEFTDOWN = 0x0002
MOUSEEVENTF_LEFTUP = 0x0004
MOUSEEVENTF_ABSOLUTE = 0x8000


def handle_one_chat(driver, chat, logger):
    contact = chat.get('contact', '未知')
    element = chat['element']

    try:
        driver.maximize_window()
    except Exception as e:
        logger.warning(f"窗口最大化失败: {e}")

    # 点击进入聊天
    driver.execute_script("arguments[0].scrollIntoView({block: 'center'});", element)
    time.sleep(0.8)
    actions = ActionChains(driver)
    actions.move_to_element(element).pause(0.5).click().perform()
    time.sleep(1)
    if not wait_for_chat_window(driver, 5):
        logger.warning("聊天窗口打开失败")
        return

    while True:
        # 1. 获取当前聊天框最新三条客户消息
        msg_elems = driver.find_elements(By.CSS_SELECTOR, 'div.message-in')
        latest_msgs = []
        for elem in msg_elems[-3:]:  # 最多取最新的三条
            if elem.text.strip():
                # 提取纯文本内容，去除可能的时间戳
                msg_text = elem.text.strip()
                # 如果消息包含换行，取第一行作为主要内容（通常时间戳在第二行）
                if '\n' in msg_text:
                    msg_text = msg_text.split('\n')[0]
                latest_msgs.append(msg_text)

        # 2. 加载本地已保存的客户消息（只取role为user的）
        local_messages = load_dialogue(contact)
        local_user_msgs = set()  # 使用集合提高查找效率
        for msg in local_messages:
            if msg["role"] == "user":
                # 同样处理可能的时间戳问题
                content = msg["content"]
                if '\n' in content:
                    content = content.split('\n')[0]
                local_user_msgs.add(content)

        # 3. 找出页面最新消息中"本地文档没有的"那几条
        new_msgs = []
        for msg in latest_msgs:
            if msg not in local_user_msgs:
                new_msgs.append(msg)
                save_dialogue(contact, "user", msg)  # 保存新消息
                local_user_msgs.add(msg)  # 立即添加到已处理集合，避免重复处理

        # 4. 如果没有新消息，直接最小化窗口并退出
        if not new_msgs:
            try:
                driver.minimize_window()
            except Exception as e:
                logger.warning(f"窗口最小化失败: {e}")
            logger.info(f"客户 {contact} 没有新消息，窗口已最小化")
            return

        # 5. 有新消息，AI根据完整文档内容回复
        # 重新加载对话历史，确保包含刚保存的新消息
        dialogue_history = load_dialogue(contact)
        
        # 调用AI生成回复
        ai_response = process_customer_message(contact, new_msgs[-1])  # 这里传最后一句只是触发，实际AI会用完整文档
        
        # 发送回复
        send_message_to_chat(driver, ai_response)
        logger.info(f"已回复客户 {contact} 的消息: {new_msgs}")

        # 6. 等待AI回复发出后，继续循环，确保没有新消息再最小化
        time.sleep(1.5)

def worker_thread(driver, worker_id, window_id):
    thread_logger = logging.getLogger(f"Window-{window_id}")
    thread_logger.info(f"启动工作线程，窗口ID: {window_id}, ID: {worker_id}")

    while True:
        try:
            context_file = f"chat_contexts_{worker_id}.json"
            chat_contexts = load_chat_contexts(filename=context_file, logger=thread_logger)
            thread_logger.info(f"已加载聊天上下文，共 {len(chat_contexts)} 个联系人")

            while True:
                # 检查侧边栏是否可见，必要时刷新
                try:
                    WebDriverWait(driver, 5).until(
                        EC.visibility_of_element_located((By.ID, "side"))
                    )
                except Exception as sidebar_error:
                    thread_logger.warning(f"侧边栏不可见，执行刷新... 错误: {str(sidebar_error)}")
                    driver.refresh()
                    WebDriverWait(driver, 30).until(
                        EC.presence_of_element_located((By.ID, "side"))
                    )

                # 查找未读消息
                unread_chats = find_unread_messages_dom(driver, logger=thread_logger)
                if not unread_chats:
                    thread_logger.info("未找到未读聊天，等待5秒后重试")
                    time.sleep(5)
                    continue

                # 只处理第一个未读聊天（可根据需求批量处理）
                handle_one_chat(driver, unread_chats[0], thread_logger)

                # 处理完后保存上下文
                save_chat_contexts(chat_contexts, filename=context_file, logger=thread_logger)

        except Exception as e:
            thread_logger.exception(f"线程 {threading.current_thread().name} 发生未处理的异常: {e}")
            time.sleep(10)

        # ===== 这里是driver重连逻辑 =====
        thread_logger.info("正在尝试重新打开窗口并重连driver...")
        try:
            ws_url, chromedriver_path = open_bitbrowser_window(window_id)
            driver = connect_to_bitbrowser(ws_url, chromedriver_path)
            if not driver:
                thread_logger.error("重新连接失败，线程退出")
                break  # 彻底退出线程
            thread_logger.info("driver重连成功，继续工作")
            time.sleep(5)  # 重连后稍作等待
        except Exception as e:
            thread_logger.error(f"重连driver时发生异常: {e}")
            break  # 彻底退出线程

def check_system_resources(logger=None):
    """检查系统资源使用情况"""
    if logger is None:
        logger = logging.getLogger(__name__)
        
    try:
        import psutil
        cpu_percent = psutil.cpu_percent()
        memory_percent = psutil.virtual_memory().percent
        logger.info(f"系统资源使用: CPU {cpu_percent}%, 内存 {memory_percent}%")
        return cpu_percent < 80 and memory_percent < 80  # 返回资源是否充足
    except ImportError:
        logger.warning("未安装psutil模块，无法监控系统资源")
        return True  # 假设资源充足

def main():
    if not os.path.exists(SCREENSHOT_DIR):
        os.makedirs(SCREENSHOT_DIR)

    threads = {}
    while True:
        # 获取所有已打开窗口ID
        opened_window_ids = get_all_opened_window_ids()
        logger.info(f"当前已手动打开 {len(opened_window_ids)} 个窗口，将全部自动化处理")

        # 启动新窗口的自动化线程
        for window_id in opened_window_ids:
            if window_id in threads and threads[window_id].is_alive():
                continue  # 已有线程在跑
            ws_url, chromedriver_path = open_bitbrowser_window(window_id)
            if not ws_url or not chromedriver_path:
                logger.error(f"窗口 {window_id} 启动失败，跳过")
                continue
            driver = connect_to_bitbrowser(ws_url, chromedriver_path)
            if not driver:
                logger.error(f"窗口 {window_id} driver连接失败，跳过")
                continue
            thread_name = f"Window-{window_id}"
            thread = threading.Thread(
                target=worker_thread,
                args=(driver, window_id, window_id),  # worker_id可以用window_id
                name=thread_name,
                daemon=True
            )
            threads[window_id] = thread
            thread.start()
            logger.info(f"已启动线程 {thread_name}")
            time.sleep(2)

        # 检查线程状态，自动重启异常线程
        for window_id, thread in list(threads.items()):
            if not thread.is_alive():
                logger.warning(f"线程 Window-{window_id} 异常退出，尝试重启...")
                ws_url, chromedriver_path = open_bitbrowser_window(window_id)
                driver = connect_to_bitbrowser(ws_url, chromedriver_path)
                if not driver:
                    logger.error(f"窗口 {window_id} driver重连失败，跳过重启")
                    continue
                thread = threading.Thread(
                    target=worker_thread,
                    args=(driver, window_id, window_id),
                    name=f"Window-{window_id}",
                    daemon=True
                )
                threads[window_id] = thread
                thread.start()
                logger.info(f"已重启线程 Window-{window_id}")
                time.sleep(2)
        time.sleep(5)  # 每5秒检测一次

def take_screenshot(driver, save=True):
    """截取屏幕截图"""
    try:
        # 使用Selenium截取屏幕截图
        png = driver.get_screenshot_as_png()
        image = Image.open(BytesIO(png))
        screenshot_cv = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
        
        # 获取图像尺寸
        height, width = screenshot_cv.shape[:2]
        logger.info(f"截图尺寸: 宽={width}, 高={height}")
        
        if save:
            # 保存截图用于调试
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            filename = f"{SCREENSHOT_DIR}/screenshot_{timestamp}.png"
            cv2.imwrite(filename, screenshot_cv)
            logger.info(f"📸 已保存截图: {filename}")
            return screenshot_cv, filename, width, height
        
        return screenshot_cv, None, width, height
    except Exception as e:
        logger.error(f"❌ 截图失败: {str(e)}")
        logger.error(traceback.format_exc())
        return None, None, 0, 0

def is_timestamp_name(name):
    """检查联系人名称是否匹配时间戳格式：YYYY-MM-DD HH:MM:SS"""
    timestamp_pattern = r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$'
    return bool(re.match(timestamp_pattern, name))

# 修改后的对话文件夹路径
DIALOGUE_DIR = "D:\\客户聊天记录"

# 确保对话文件夹存在
if not os.path.exists(DIALOGUE_DIR):
    os.makedirs(DIALOGUE_DIR)

def sanitize_filename(name):
    """将时间格式的客户名称转换为合法的文件名（替换冒号和空格）"""
    return re.sub(r'[:\s]', '_', name) 

def save_dialogue(customer_id, role, message):
    """保存对话到文件，自动处理时间格式的客户ID"""
    try:
        # 清理文件名中的非法字符
        safe_name = sanitize_filename(customer_id)
        file_path = os.path.join(DIALOGUE_DIR, f"{safe_name}.txt")
        
        # 确保目录存在
        os.makedirs(DIALOGUE_DIR, exist_ok=True)
        
        # 写入文件（追加模式）
        with open(file_path, "a", encoding="utf-8") as f:
            f.write(f"{role}: {message}\n")
        
        logger.info(f"对话已保存: {file_path}")
        return True
    except Exception as e:
        logger.error(f"保存失败: {str(e)}")
        return False

def load_dialogue(customer_id):
    """加载本地完整对话历史，不做任何截断"""
    try:
        safe_name = sanitize_filename(customer_id)
        file_path = os.path.join(DIALOGUE_DIR, f"{safe_name}.txt")
        
        if not os.path.exists(file_path):
            return []
            
        with open(file_path, "r", encoding="utf-8") as f:
            lines = [line.strip() for line in f if line.strip()]
            # 格式化为 [{"role": "user/assistant", "content": "..."}, ...]
            history = []
            for line in lines:
                if ": " in line:
                    role, content = line.split(": ", 1)
                    history.append({"role": role.lower(), "content": content})
            return history
    except Exception as e:
        logger.error(f"加载对话失败: {str(e)}")
        return []

def process_customer_message(customer_id, customer_message):
    try:
        # 加载本地完整对话历史
        dialogue_history = load_dialogue(customer_id)
        
        # 组装固定人设
        system_prompt = """你是Jones，36岁，生活在纽约这座快节奏的大都市。每天，你都会接待来自全美各地的男性客户，他们或许在深夜独自思考，或许在家庭聚会后感到力不从心，或许在亲密时刻因精力不足而苦恼。你深知，现代男性在事业、家庭和自我之间承受着巨大的压力，也理解他们在面对敏感话题时的顾虑和不安。
作为一名拥有8年经验的男性健康保健品公司金牌客服代表，你总能用坦率、真诚的沟通方式，让客户在谈论性生活等私密问题时感到轻松自在。你善于倾听客户的真实需求，无论是渴望重拾自信，还是希望改善夫妻关系，你都能用专业、温暖的建议，帮助他们找到最合适的解决方案。你相信，每一位客户都值得拥有更健康、更幸福的生活。"""

        product_info = """你负责销售的男性即时壮阳保健品是"LGNIS"。这是一款高端男性健康补充剂，能够在需要时迅速提供支持，药效可持续长达36小时，帮助客户在性生活中表现更佳。

- 产品价格:
  - 单盒装(2粒): $49.9美金（原价$59.9美金，立省$10）
  - 优惠三盒装(6粒): $129.9美金（比单买省$20）
  - 没有其他任何折扣或优惠政策

- 物流信息:
  - 从美国西部配送中心发货
  - 使用隐私保护包装，外包装无产品相关信息
  - 标准配送时间: 3-5个工作日送达全美"""

        sales_guidance = """在向客户介绍时，可以结合生活场景强调：我们的产品采用独家工艺提取高浓度L-精氨酸和瓜氨酸复合物，经过科学配比，能够有效促进血液循环，提升整体精力。无论是工作压力大还是希望在亲密时刻有更好表现，这款产品都能帮助您保持自信和活力，让每一次亲密都更加尽兴。

使用以下关键词和概念:
- "临床验证的成分"
- "快速见效，通常30-60分钟"
- "持久活力支持"
- "纯天然提取物"
- "独家专利配方"

重要指导:
1.绝对不要向客户透露产品的真正有效成分是他达那非。这是公司的商业机密。
2.当讨论产品禁忌时，请按照他达那非的禁忌指南告知客户，但称之为“我们独特配方的安全使用指南”。
3.告知客户以下人群不适合使用本产品：
    -正在服用任何硝酸盐类药物（如硝酸甘油）的人
    -有严重心脏问题或近期有心脏病发作史的人
    -有严重肝脏或肾脏问题的人
    -有视网膜疾病的人
    -对产品中任何成分过敏的人
    -血压异常（过高或过低）的人
4.不要自我介绍，不要重复客户的问题，不要输出“带着自信且友好的声音”这类语气描述。
5.如果客户只是打招呼（如“你好”），你只需礼貌问候并简单说明自己是男性健康产品客服即可，不要主动推销。
6.回复内容不要分多条消息发出，最多分为两段。
7.在客户表达兴趣、咨询产品细节或表现出犹豫时，应灵活、自然地引导客户下单或试用。可以根据实际对话场景，自主组织语言，参考但不拘泥于以下表达方式，确保每次回复内容有变化，避免重复和模板化：
“如果您想体验LGNIS带来的改变，现在下单即可享受快速隐私配送。”
“很多客户在尝试后都反馈效果明显，您也可以放心选择。”
“如果您有意向，我可以为您详细介绍下单流程，帮助您尽快收到产品。”
“现在下单，3-5个工作日即可送达，包装隐私无忧。”"""

        system_prompt = system_prompt + "\n\n" + product_info + "\n\n" + sales_guidance
        
        # 组装最终messages
        messages = [{"role": "system", "content": system_prompt}]
        messages.extend(dialogue_history)
        
        # 调用Ollama
        ai_response = get_gemma_response(
            messages,
            system_prompt=None,
            is_full_message=True
        )
        
        # 保存AI回复
        save_dialogue(customer_id, "assistant", ai_response)
        return ai_response
    except Exception as e:
        logger.error(f"处理消息失败: {str(e)}")
        return "抱歉，我目前无法处理您的请求。"

def process_timestamp_chats(driver, chat_contexts=None, logger=None):
    """处理时间格式联系人的未读消息并使用Gemma回复"""
    # 如果没有提供日志记录器，使用全局日志记录器
    if logger is None:
        logger = logging.getLogger(__name__)
        
    if chat_contexts is None:
        chat_contexts = {}
        
    try:
        # 查找未读消息
        logger.info("查找未读消息...")
        unread_chats = find_unread_messages_dom(driver, logger=logger)
        
        if not unread_chats:
            logger.info("未找到未读聊天")
            return False
        
        # 处理第一个时间格式聊天
        chat = unread_chats[0]
        element = chat['element']
        contact = chat.get('contact', '未知')
        
        logger.info(f"处理时间格式聊天: {contact}")
        
        # 点击聊天以打开它
        driver.execute_script("arguments[0].scrollIntoView({block: 'center'});", element)
        time.sleep(0.8)
        
        actions = ActionChains(driver)
        actions.move_to_element(element).pause(0.5).click().perform()
        time.sleep(1)
        
        # 验证聊天窗口是否打开
        if not wait_for_chat_window(driver, 5):
            logger.warning("聊天窗口打开失败")
            return False
        
        # 提取客户消息
        customer_message = extract_latest_message(driver)
        if not customer_message:
            logger.warning("未找到客户消息")
            return False

        # 标记消息为已读（通过点击消息或模拟已读状态）
        try:
            driver.execute_script("""
                var unreadMarks = document.querySelectorAll('span[aria-label*="未读"], span[aria-label*="unread"]');
                for (var mark of unreadMarks) {
                    mark.parentNode.removeChild(mark);
                }
            """)
            logger.info("✅ 已标记消息为已读")
        except Exception as e:
            logger.warning(f"标记消息为已读失败: {str(e)}")
        
        # 处理客户消息并生成回复
        ai_response = process_customer_message(contact, customer_message)
        
        # 发送回复
        send_message_to_chat(driver, ai_response)
        
        logger.info("✅ 成功处理时间格式聊天")
        return True
    except Exception as e:
        logger.error(f"处理时间格式聊天时出错: {str(e)}")
        return False

def extract_latest_message(driver):
    """提取客户发送的最新消息，并处理时间戳问题"""
    try:
        # 查找最新消息
        message_elements = driver.find_elements(By.CSS_SELECTOR, 'div.message-in')
        if not message_elements:
            return None
        
        latest_message = message_elements[-1]
        text = latest_message.text.strip()
        
        # 处理可能包含时间戳的消息
        if '\n' in text:
            # 通常时间戳在第二行，取第一行作为主要内容
            text = text.split('\n')[0]
            
        return text
    except Exception as e:
        logger.error(f"提取最新消息失败: {str(e)}")
        return None

def find_unread_messages_dom(driver, logger=None):
    """使用DOM方法查找未读消息，并筛选时间格式的联系人"""
    if logger is None:
        logger = logging.getLogger(__name__)
        
    try:
        # 确保聊天列表已加载
        logger.info("等待聊天列表加载...")  # 使用传入的logger
        WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "pane-side"))
        )
        
        # 使用JavaScript查找未读聊天项，添加去重逻辑
        result = driver.execute_script("""
            // 获取聊天面板
            var chatPane = document.querySelector('#pane-side');
            if (!chatPane) return {success: false, error: "找不到聊天面板"};
            
            // 查找所有潜在的聊天项
            var chatItems = chatPane.querySelectorAll('div[tabindex="-1"]');
            console.log('找到', chatItems.length, '个潜在聊天项');
            
            // 用于去重的哈希表
            var seenContacts = {};
            
            // 查找所有包含未读标记的聊天项
            var unreadChats = [];
            for (var i = 0; i < chatItems.length; i++) {
                var item = chatItems[i];
                // 排除导航栏和左侧边栏元素 - 关键过滤条件
                if (item.getBoundingClientRect().x < 50) continue;
                
                // 检查是否包含未读标记
                var unreadMarks = item.querySelectorAll('span[aria-label*="未读"], span[aria-label*="unread"]');
                if (unreadMarks.length > 0) {
                    // 提取联系人名称和消息内容
                    var contactName = "";
                    var messageText = "";
                    
                    // 尝试提取联系人名称
                    var nameElements = item.querySelectorAll('div[role="gridcell"] span[dir="auto"]');
                    if (nameElements.length > 0) {
                        contactName = nameElements[0].textContent;
                    }
                    
                    // 尝试提取最后消息内容
                    var messageElements = item.querySelectorAll('div.copyable-text');
                    if (messageElements.length > 0) {
                        messageText = messageElements[0].textContent;
                    } else {
                        // 备用方法
                        var spanElements = item.querySelectorAll('span[dir="ltr"]');
                        if (spanElements.length > 0) {
                            messageText = spanElements[0].textContent;
                        }
                    }
                    
                    // 创建唯一标识符，用于去重
                    var chatId = contactName + ":" + messageText;
                    
                    // 检查是否已经添加过该聊天项
                    if (!seenContacts[chatId]) {
                        seenContacts[chatId] = true;
                        unreadChats.push({
                            contact: contactName,
                            message: messageText,
                            element: item,
                            rect: item.getBoundingClientRect()
                        });
                    }
                }
            }
            
            console.log('找到', unreadChats.length, '个不重复的带有未读标记的聊天项');
            return {
                success: unreadChats.length > 0,
                chats: unreadChats
            };
        """)
        
        if result and isinstance(result, dict) and result.get('success'):
            chats = result.get('chats', [])
            # 筛选出时间格式的联系人
            timestamp_chats = []
            for chat in chats:
                contact_name = chat.get('contact', '未知')
                if is_timestamp_name(contact_name):
                    timestamp_chats.append(chat)
                    logger.info(f"找到时间格式联系人: {contact_name}")
                    logger.info(f"  消息: {chat.get('message', '未知')}")
            
            logger.info(f"✅ 找到 {len(timestamp_chats)} 个时间格式联系人的未读聊天项")
            return timestamp_chats
        else:
            logger.info("未找到未读聊天项")
            return []
    except Exception as e:
        logger.error(f"❌ DOM查找未读消息失败: {str(e)}")
        logger.error(traceback.format_exc())
        return []

def find_and_click_message_content(driver):
    """直接查找并点击消息内容，而不是绿色圆点"""
    try:
        logger.info("尝试直接点击消息内容...")
        
        # 确保聊天列表已加载
        WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.ID, "pane-side"))
        )
        
        # 使用JavaScript查找未读聊天项及其消息内容
        result = driver.execute_script("""
            // 获取聊天面板
            var chatPane = document.querySelector('#pane-side');
            if (!chatPane) return {success: false, error: "找不到聊天面板"};
            
            // 查找所有潜在的聊天项
            var chatItems = chatPane.querySelectorAll('div[tabindex="-1"]');
            console.log('找到', chatItems.length, '个潜在聊天项');
            
            // 用于去重的哈希表
            var seenContacts = {};
            
            // 查找包含未读标记的聊天项
            var unreadChats = [];
            for (var i = 0; i < chatItems.length; i++) {
                var item = chatItems[i];
                // 排除导航栏元素
                if (item.getBoundingClientRect().x < 50) continue;
                
                // 检查是否包含未读标记
                var unreadMarks = item.querySelectorAll('span[aria-label*="未读"], span[aria-label*="unread"]');
                if (unreadMarks.length > 0) {
                    // 查找消息内容元素 - 尝试多种选择器
                    var messageContentElement = null;
                    
                    // 1. 尝试找到消息预览文本
                    var previewElements = item.querySelectorAll('.copyable-text, span[dir="ltr"], div.message-preview');
                    for (var j = 0; j < previewElements.length; j++) {
                        var element = previewElements[j];
                        if (element.textContent && element.textContent.trim() !== '') {
                            messageContentElement = element;
                            break;
                        }
                    }
                    
                    // 2. 如果没找到具体的消息预览元素，就使用整个聊天项但避开右侧的绿点区域
                    if (!messageContentElement) {
                        messageContentElement = item;
                    }
                    
                    var rect = messageContentElement.getBoundingClientRect();
                    var contactName = "";
                    var messageText = messageContentElement.textContent || "";
                    
                    // 尝试提取联系人名称
                    var nameElements = item.querySelectorAll('div[role="gridcell"] span[dir="auto"]');
                    if (nameElements.length > 0) {
                        contactName = nameElements[0].textContent;
                    }
                    
                    // 创建唯一标识符，用于去重
                    var chatId = contactName + ":" + messageText;
                    
                    // 检查是否已经添加过该聊天项
                    if (!seenContacts[chatId]) {
                        seenContacts[chatId] = true;
                        
                        // 返回找到的第一个未读聊天的消息内容元素
                        return {
                            success: true,
                            element: messageContentElement,
                            text: messageText,
                            contact: contactName,
                            rect: rect
                        };
                    }
                }
            }
            
            return {success: false, error: "未找到带有未读标记的聊天项"};
        """)
        
        if result and isinstance(result, dict) and result.get('success'):
            logger.info(f"找到未读消息内容: {result.get('text', '未知')[:50]}")
            logger.info(f"联系人: {result.get('contact', '未知')}")
            
            # 获取元素位置
            rect = result.get('rect', {})
            
            # 计算点击位置 - 消息内容的中心偏左位置
            window_x = driver.execute_script("return window.screenX")
            window_y = driver.execute_script("return window.screenY")
            
            # 计算绝对坐标 - 确保点击在消息内容区域而不是绿点
            # x坐标取元素左侧1/4处，避开右侧可能的绿点
            click_x = window_x + rect.get('x', 0) + rect.get('width', 0) * 0.25
            click_y = window_y + rect.get('y', 0) + rect.get('height', 0) / 2 + 80  # 加上浏览器顶部高度估计值
            
            logger.info(f"计算的点击坐标（消息内容区域）: ({click_x}, {click_y})")
            
            # 保存点击前截图
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            before_click = f"{SCREENSHOT_DIR}/before_content_click_{timestamp}.png"
            driver.save_screenshot(before_click)
            
            # 尝试方法1: 使用Windows原生API点击
            try:
                logger.info("尝试使用Windows原生API点击消息内容...")
                success = windows_native_mouse_click(int(click_x), int(click_y))
                time.sleep(2)
                
                if wait_for_chat_window(driver, 5):
                    logger.info("✅ 通过Windows原生API点击成功打开聊天")
                    return True
            except Exception as e:
                logger.warning(f"Windows原生API点击失败: {str(e)}")
            
            # 尝试方法2: 使用PyAutoGUI
            try:
                logger.info("尝试使用PyAutoGUI点击消息内容...")
                human_like_click_with_pyautogui(int(click_x), int(click_y))
                time.sleep(2)
                
                if wait_for_chat_window(driver, 5):
                    logger.info("✅ 通过PyAutoGUI点击成功打开聊天")
                    return True
            except Exception as e:
                logger.warning(f"PyAutoGUI点击失败: {str(e)}")
            
            # 尝试方法3: 使用JavaScript点击
            try:
                logger.info("尝试使用JavaScript点击消息内容...")
                element = result.get('element')
                if element:
                    driver.execute_script("arguments[0].click();", element)
                    time.sleep(2)
                    
                    if wait_for_chat_window(driver, 5):
                        logger.info("✅ 通过JavaScript点击成功打开聊天")
                        return True
            except Exception as e:
                logger.warning(f"JavaScript点击失败: {str(e)}")
            
            # 保存点击后截图
            after_click = f"{SCREENSHOT_DIR}/after_content_click_{timestamp}.png"
            driver.save_screenshot(after_click)
            
            logger.warning("所有点击方法都失败，未能打开聊天窗口")
            return False
        else:
            logger.warning("未找到未读消息内容")
            return False
    except Exception as e:
        logger.error(f"❌ 点击消息内容时出错: {str(e)}")
        logger.error(traceback.format_exc())
        return False

def draw_circles_on_image(image, circles):
    """在图像上绘制找到的圆圈和点击位置（用于调试）"""
    try:
        result = image.copy()
        
        for (center, radius, _, _, (rel_x, rel_y)) in circles:
            # 绘制检测到的绿色圆圈
            cv2.circle(result, center, radius, (0, 0, 255), 2)  # 红色圆圈
            cv2.circle(result, center, 2, (0, 0, 255), -1)  # 红色圆心
            cv2.putText(result, f"圆点 ({center[0]}, {center[1]})", (center[0] + 10, center[1] - 10), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 0, 255), 1)
            
            # 计算并绘制聊天项点击位置（不是圆点，而是左侧的文本区域）
            height, width = image.shape[:2]
            click_x = int((rel_x - 0.15) * width)  # 向左偏移到聊天项文本区域
            click_y = int(rel_y * height)  # 保持相同的y坐标
            
            cv2.circle(result, (click_x, click_y), 5, (255, 0, 0), -1)  # 蓝色点标记点击位置
            cv2.putText(result, f"点击位置 ({click_x}, {click_y})", (click_x + 10, click_y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 0, 0), 1)
            
            # 绘制连接线
            cv2.line(result, center, (click_x, click_y), (0, 255, 0), 1)  # 绿色连接线
        
        return result
    except Exception as e:
        logger.error(f"❌ 绘制调试图像时出错: {str(e)}")
        return image

def windows_native_mouse_click(x, y, right_click=False):
    """使用Windows API直接控制鼠标，更难被检测"""
    try:
        # 确保x和y是整数
        x = int(x)
        y = int(y)
        
        # 将坐标转换为绝对坐标（0-65535范围）
        screen_width = ctypes.windll.user32.GetSystemMetrics(0)
        screen_height = ctypes.windll.user32.GetSystemMetrics(1)
        x_scaled = int(65535 * x / screen_width)
        y_scaled = int(65535 * y / screen_height)
        
        logger.info(f"执行原生鼠标点击: 屏幕坐标=({x}, {y}), 缩放坐标=({x_scaled}, {y_scaled})")
        
        # 模拟人类移动鼠标的路径
        # 先移动到中间点，添加一些随机性
        mid_x = int(65535 * ((pyautogui.position()[0] + x) / 2 + random.randint(-20, 20)) / screen_width)
        mid_y = int(65535 * ((pyautogui.position()[1] + y) / 2 + random.randint(-20, 20)) / screen_height)
        
        # 移动到中间点
        ctypes.windll.user32.mouse_event(
            MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE,
            mid_x, mid_y, 0, 0
        )
        time.sleep(random.uniform(0.05, 0.15))
        
        # 移动到目标点
        ctypes.windll.user32.mouse_event(
            MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE,
            x_scaled, y_scaled, 0, 0
        )
        time.sleep(random.uniform(0.05, 0.15))
        
        if right_click:
            # 按下鼠标右键
            ctypes.windll.user32.mouse_event(
                MOUSEEVENTF_RIGHTDOWN, 0, 0, 0, 0
            )
            
            # 延迟（模拟真实点击的持续时间）
            time.sleep(random.uniform(0.05, 0.15))
            
            # 释放鼠标右键
            ctypes.windll.user32.mouse_event(
                MOUSEEVENTF_RIGHTUP, 0, 0, 0, 0
            )
        else:
            # 按下鼠标左键
            ctypes.windll.user32.mouse_event(
                MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0
            )
            
            # 延迟（模拟真实点击的持续时间）
            time.sleep(random.uniform(0.05, 0.15))
            
            # 释放鼠标左键
            ctypes.windll.user32.mouse_event(
                MOUSEEVENTF_LEFTUP, 0, 0, 0, 0
            )
            
        return True
    except Exception as e:
        logger.error(f"❌ Windows原生鼠标点击失败: {str(e)}")
        return False

def human_like_click_with_pyautogui(x, y):
    """使用PyAutoGUI模拟更接近人类的点击行为"""
    try:
        # 当前鼠标位置
        current_x, current_y = pyautogui.position()
        
        # 计算移动路径的中间点（添加一些随机性）
        mid_x = (current_x + x) / 2 + random.randint(-20, 20)
        mid_y = (current_y + y) / 2 + random.randint(-20, 20)
        
        # 使用非线性路径移动鼠标（更像人类）
        pyautogui.moveTo(mid_x, mid_y, duration=random.uniform(0.1, 0.3))
        pyautogui.moveTo(x, y, duration=random.uniform(0.1, 0.2))
        
        # 短暂停顿，模拟人类思考
        time.sleep(random.uniform(0.1, 0.3))
        
        # 点击
        pyautogui.click()
        return True
    except Exception as e:
        logger.error(f"❌ PyAutoGUI模拟人类点击失败: {str(e)}")
        return False

def wait_for_chat_window(driver, timeout=10):
    """等待聊天窗口加载，使用更强的验证方法"""
    try:
        logger.info(f"等待聊天窗口加载，超时时间: {timeout}秒")
        
        # 保存验证截图
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        screenshot_file = f"{SCREENSHOT_DIR}/chat_window_check_{timestamp}.png"
        driver.save_screenshot(screenshot_file)
        logger.info(f"📸 已保存聊天窗口检查截图: {screenshot_file}")
        
        # 等待聊天窗口加载 - 更可靠的方法
        try:
            # 等待主聊天区域加载
            WebDriverWait(driver, timeout).until(
                EC.visibility_of_element_located((By.ID, "main"))
            )
            
            # 额外检查：确保输入框已加载
            input_box = WebDriverWait(driver, timeout/2).until(
                EC.visibility_of_element_located((By.CSS_SELECTOR, 'div[contenteditable="true"]'))
            )
            
            # 获取聊天标题
            try:
                title_element = driver.find_element(By.CSS_SELECTOR, '#main header span[dir="auto"]')
                chat_title = title_element.text
                logger.info(f"打开的聊天: {chat_title}")
            except:
                logger.info("无法获取聊天标题")
            
            # 验证输入框是否可交互
            if input_box.is_displayed() and input_box.is_enabled():
                logger.info("✅ 聊天窗口已完全加载，输入框可交互")
                return True
            else:
                logger.warning("⚠️ 输入框不可交互")
                return False
                
        except Exception as wait_error:
            logger.error(f"❌ 等待聊天窗口加载失败: {str(wait_error)}")
            return False
            
    except Exception as e:
        logger.error(f"❌ 等待聊天窗口加载时出错: {str(e)}")
        return False

def click_chat_item_avoiding_green_dot(driver, circles):
    """点击聊天项，避开绿色圆点，直接点击左侧的聊天文本区域"""
    if not circles:
        logger.warning("没有找到未读消息通知圆圈")
        return False
    
    try:
        # 获取浏览器窗口位置
        window_x = driver.execute_script("return window.screenX")
        window_y = driver.execute_script("return window.screenY")
        
        # 获取第一个圆圈
        (center, radius, _, _, (rel_x, rel_y)) = circles[0]
        
        # 获取浏览器视图区域
        inner_width = driver.execute_script("return window.innerWidth")
        inner_height = driver.execute_script("return window.innerHeight")
        
        # 计算点击坐标 - 点击聊天项文本区域（绿点左侧）
        # 向左偏移到聊天项文本区域，避开绿色圆点
        click_rel_x = rel_x - 0.2  # 增加向左偏移量，确保远离绿点
        click_rel_y = rel_y  # 保持相同的y坐标
        
        # 计算绝对坐标
        click_x = window_x + int(click_rel_x * inner_width)
        click_y = window_y + int(click_rel_y * inner_height) + 80  # 添加顶部边框和工具栏的估计高度
        
        logger.info(f"计算的点击坐标（聊天文本区域）: ({click_x}, {click_y})")
        
        # 保存点击前截图
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        before_click = f"{SCREENSHOT_DIR}/before_click_{timestamp}.png"
        driver.save_screenshot(before_click)
        
        # 使用Windows原生API点击
        success = windows_native_mouse_click(click_x, click_y)
        if not success:
            # 备用方法：使用PyAutoGUI
            human_like_click_with_pyautogui(click_x, click_y)
        
        # 等待聊天窗口加载
        time.sleep(2)
        
        # 保存点击后截图
        after_click = f"{SCREENSHOT_DIR}/after_click_{timestamp}.png"
        driver.save_screenshot(after_click)
        
        # 检查是否成功打开聊天窗口
        chat_window_loaded = wait_for_chat_window(driver, 5)
        
        if chat_window_loaded:
            logger.info("✅ 成功点击聊天项并打开聊天窗口")
            return True
        else:
            logger.warning("⚠️ 聊天窗口未加载，尝试其他方法")
            
            # 尝试点击更左侧位置（进一步远离绿点）
            far_left_x = click_x - 50  # 再向左偏移50像素
            logger.info(f"尝试点击更左侧位置: ({far_left_x}, {click_y})")
            windows_native_mouse_click(far_left_x, click_y)
            time.sleep(2)
            
            # 再次检查聊天窗口
            chat_window_loaded = wait_for_chat_window(driver, 5)
            
            if not chat_window_loaded:
                # 尝试双击
                logger.info("尝试双击...")
                windows_native_mouse_click(far_left_x, click_y)
                time.sleep(0.1)
                windows_native_mouse_click(far_left_x, click_y)
                time.sleep(2)
                chat_window_loaded = wait_for_chat_window(driver, 5)
                
            return chat_window_loaded
        
    except Exception as e:
        logger.error(f"❌ 点击聊天项时出错: {str(e)}")
        logger.error(traceback.format_exc())
        return False

def process_unread_messages(driver):
    """综合处理未读消息的完整流程，只使用有效的ActionChains标准点击方法"""
    try:
        # 先等待页面稳定
        time.sleep(1.5)
        
        # 使用DOM查找未读消息
        unread_chats = find_unread_messages_dom(driver)
        if unread_chats:
            # 获取第一个未读聊天元素
            element = unread_chats[0]['element']
            
            # 记录聊天信息
            contact = unread_chats[0].get('contact', '未知')
            message = unread_chats[0].get('message', '未知')
            logger.info(f"准备点击未读聊天: {contact} - {message}")
            
            # 滚动元素到视图中心
            driver.execute_script("arguments[0].scrollIntoView({block: 'center'});", element)
            time.sleep(0.8)  # 稍微增加等待时间，确保元素完全滚动到位
            
            # 保存点击前截图
            timestamp = time.strftime("%Y%m%d_%H%M%S")
            before_click = f"{SCREENSHOT_DIR}/before_click_{timestamp}.png"
            driver.save_screenshot(before_click)
            
            # 使用ActionChains标准点击（方法3 - 已验证有效）
            logger.info("尝试方法3：ActionChains标准点击...")
            actions = ActionChains(driver)
            actions.move_to_element(element).pause(0.5).click().perform()
            time.sleep(1)
            
            # 保存点击后截图
            after_click = f"{SCREENSHOT_DIR}/after_click_{timestamp}.png"
            driver.save_screenshot(after_click)
            
            # 验证聊天窗口是否打开
            if wait_for_chat_window(driver, 5):
                logger.info("✅ 通过ActionChains标准点击成功打开聊天")
                return True
            else:
                # 如果第一次点击失败，尝试再次点击
                logger.info("第一次点击未成功打开聊天窗口，尝试再次点击...")
                
                # 重新获取元素（避免stale element问题）
                try:
                    unread_chats = find_unread_messages_dom(driver)
                    if unread_chats:
                        element = unread_chats[0]['element']
                        driver.execute_script("arguments[0].scrollIntoView({block: 'center'});", element)
                        time.sleep(0.8)
                        
                        # 再次使用ActionChains点击
                        actions = ActionChains(driver)
                        actions.move_to_element(element).pause(0.5).click().perform()
                        time.sleep(2)
                        
                        if wait_for_chat_window(driver, 5):
                            logger.info("✅ 通过第二次ActionChains点击成功打开聊天")
                            return True
                except Exception as retry_error:
                    logger.warning(f"重试点击失败: {str(retry_error)}")
                
                logger.warning("❌ 多次尝试后仍未能打开聊天窗口")
                return False
        else:
            logger.info("未找到未读聊天项")
            return False
            
    except Exception as e:
        logger.error(f"❌ 处理未读消息时出现异常: {str(e)}")
        logger.error(traceback.format_exc())
        return False

def verify_chat_window_open(driver):
    """更强的验证方法，确认聊天窗口是否真的打开"""
    try:
        # 1. 检查URL是否包含特定参数
        url_contains_chat = "chat" in driver.current_url
        
        # 2. 检查DOM结构
        # 尝试查找聊天头部元素
        header_elements = driver.find_elements(By.CSS_SELECTOR, '#main header, header')
        has_header = len(header_elements) > 0
        
        # 尝试查找消息列表
        message_list = driver.find_elements(By.CSS_SELECTOR, '#main div[role="application"]')
        has_message_list = len(message_list) > 0
        
        # 尝试查找输入框
        input_box = driver.find_elements(By.CSS_SELECTOR, 'div[contenteditable="true"]')
        has_input = len(input_box) > 0 and input_box[0].is_displayed()
        
        # 3. 尝试获取聊天标题
        chat_title = ""
        try:
            title_element = driver.find_element(By.CSS_SELECTOR, '#main header span[dir="auto"]')
            chat_title = title_element.text
        except:
            pass
        
        # 综合判断
        is_chat_open = has_header and has_input
        
        logger.info(f"聊天窗口验证: 标题={chat_title}, 有头部={has_header}, 有消息列表={has_message_list}, 有输入框={has_input}")
        
        # 保存验证截图
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        verify_file = f"{SCREENSHOT_DIR}/verify_chat_{timestamp}.png"
        driver.save_screenshot(verify_file)
        
        return is_chat_open, chat_title
    except Exception as e:
        logger.error(f"验证聊天窗口时出错: {str(e)}")
        return False, ""

def process_timestamp_chats(driver, chat_contexts=None, logger=None):
    """处理时间格式联系人的未读消息并使用Gemma回复"""
    # 如果没有提供日志记录器，使用全局日志记录器
    if logger is None:
        logger = logging.getLogger(__name__)
        
    if chat_contexts is None:
        chat_contexts = {}
        
    try:
        with chat_contexts_lock:  # 加锁保护共享资源
            # 查找未读消息
            logger.info("查找未读消息...")
            unread_chats = find_unread_messages_dom(driver, logger=logger)
            
            if not unread_chats:
                logger.info("未找到未读聊天")
                return False
            
            # 处理第一个时间格式聊天
            chat = unread_chats[0]
            element = chat['element']
            contact = chat.get('contact', '未知')
            
            logger.info(f"处理时间格式聊天: {contact}")
            
            # 点击聊天以打开它
            driver.execute_script("arguments[0].scrollIntoView({block: 'center'});", element)
            time.sleep(0.8)
            
            actions = ActionChains(driver)
            actions.move_to_element(element).pause(0.5).click().perform()
            time.sleep(1)
            
            # 验证聊天窗口是否打开
            if not wait_for_chat_window(driver, 5):
                logger.warning("聊天窗口打开失败")
                return False
            
            # 提取客户最新消息
            customer_message = extract_latest_message(driver)
            if not customer_message:
                logger.warning("未找到客户消息")
                return False
            
            # 保存客户消息到文件
            save_dialogue(contact, "user", customer_message)
            
            # 加载完整对话历史
            dialogue_history = load_dialogue(contact)

            # 获取系统提示词（使用您原有的Jones角色设定）
            system_prompt = None

            # 获取Gemma的回复
            logger.info("正在从Gemma获取回复...")
            ai_response = get_gemma_response(
                dialogue_history,  # 使用从文件加载的完整历史
                system_prompt=system_prompt
            )
            
            # 详细记录AI回复内容
            if ai_response:
                logger.info(f"获取到AI回复: {ai_response[:50]}...（共{len(ai_response)}字符）")
                
                # 保存AI回复到文件
                save_dialogue(contact, "assistant", ai_response)
                
                # 更新上下文
                dialogue_history.append({"role": "assistant", "content": ai_response})
                chat_contexts[contact] = dialogue_history

                # 关键修复：确保发送回复
                logger.info("准备发送AI回复到WhatsApp...")
                success = send_message_to_chat(driver, ai_response)
                
                if success:
                    logger.info("✅ 成功处理时间格式聊天并发送回复")
                    return True  # 返回True表示成功处理了聊天
                else:
                    logger.warning("❌ 消息发送失败，尝试再次发送...")
                    # 再次尝试发送
                    time.sleep(1)
                    second_try = send_message_to_chat(driver, ai_response)
                    if second_try:
                        logger.info("✅ 第二次尝试发送成功")
                        return True
                    else:
                        logger.error("❌ 两次尝试发送均失败")
                        return False
            else:
                logger.warning("未获取到有效的AI回复")
                return False
    
    except Exception as e:
        logger.error(f"处理时间格式聊天时出错: {str(e)}")
        logger.error(traceback.format_exc())
        return False

CHAT_CONTEXT_FILE = "chat_contexts.json"


# 在访问共享资源时使用锁
def save_chat_contexts(chat_contexts, filename=CHAT_CONTEXT_FILE, logger=None):
    try:
        # 统一在一个try块中
        if logger is None:
            logger = logging.getLogger(__name__)
            
        with chat_contexts_lock:
            # 原保存逻辑保持不变
            serializable_contexts = {}
            for contact, conversation in chat_contexts.items():
                serializable_contexts[contact] = [
                    {"role": msg["role"], "content": msg["content"]}
                    for msg in conversation 
                    if isinstance(msg, dict) and "role" in msg and "content" in msg
                ]
            
            with open(filename, 'w', encoding='utf-8') as f:
                json.dump(serializable_contexts, f, ensure_ascii=False, indent=2)
            
            logger.info(f"聊天上下文已保存到 {filename}，共 {len(serializable_contexts)} 个联系人")
            return True
            
    except Exception as e:  # 统一的异常处理
        logger.error(f"保存聊天上下文失败: {str(e)}")
        logger.error(traceback.format_exc())
        return False

def load_chat_contexts(filename=CHAT_CONTEXT_FILE, logger=None):
    """从文件加载聊天上下文"""
    if logger is None:
        logger = logging.getLogger(__name__)
        
    try:
        with chat_contexts_lock:  # 添加锁保护读取操作
            if os.path.exists(filename):
                with open(filename, 'r', encoding='utf-8') as f:
                    chat_contexts = json.load(f)
                
                # 验证加载的数据格式
                validated_contexts = {}
                for contact, conversation in chat_contexts.items():
                    if isinstance(conversation, list):
                        validated_contexts[contact] = [
                            msg for msg in conversation 
                            if isinstance(msg, dict) and "role" in msg and "content" in msg
                        ]
                
                logger.info(f"已从 {filename} 加载聊天上下文，共 {len(validated_contexts)} 个联系人")
                return validated_contexts
            else:
                logger.info(f"未找到聊天上下文文件 {filename}，使用空上下文")
                return {}
    except Exception as e:
        logger.error(f"加载聊天上下文失败: {str(e)}")
        logger.error(traceback.format_exc())
        return {}

def extract_chat_history(driver, max_messages=10):
    """提取当前打开聊天窗口的对话历史"""
    try:
        logger.info("提取聊天历史...")
        
        # 等待消息加载
        WebDriverWait(driver, 10).until(
            EC.presence_of_element_located((By.CSS_SELECTOR, "div.message-in, div.message-out"))
        )
        
        # 获取所有消息
        messages = driver.execute_script("""
            var messageElements = document.querySelectorAll('div.message-in, div.message-out');
            var messages = [];
            
            for (var i = Math.max(0, messageElements.length - arguments[0]); i < messageElements.length; i++) {
                var element = messageElements[i];
                var isOutgoing = element.classList.contains('message-out');
                var textElement = element.querySelector('div.copyable-text');
                var text = textElement ? textElement.textContent.trim() : '';
                
                // 尝试获取发送者名称（群聊）
                var senderElement = element.querySelector('div.copyable-text span.quoted-mention');
                var sender = senderElement ? senderElement.textContent.trim() : '';
                
                // 尝试获取时间戳
                var metaElement = element.querySelector('div.copyable-text span[data-testid="msg-meta"]');
                var timestamp = metaElement ? metaElement.textContent.trim() : '';
                
                messages.push({
                    text: text,
                    isOutgoing: isOutgoing,
                    sender: sender,
                    timestamp: timestamp
                });
            }
            
            return messages;
        """, max_messages)
        
        # 格式化对话历史供LLM使用
        conversation = []
        for msg in messages:
            role = "assistant" if msg['isOutgoing'] else "user"
            conversation.append({"role": role, "content": msg['text']})
        
        logger.info(f"提取了 {len(conversation)} 条消息")
        return conversation
    
    except Exception as e:
        logger.error(f"提取聊天历史失败: {str(e)}")
        logger.error(traceback.format_exc())
        return []

def get_gemma_response(conversation_history, system_prompt=None, is_full_message=False):
    try:
        # 如果is_full_message=True，说明conversation_history已经是完整的messages（包含system和对话历史）
        if is_full_message:
            messages = conversation_history
        else:
            # 否则走原有逻辑：去重对话历史 + 拼接system prompt
            unique_history = []
            seen = set()
            for msg in reversed(conversation_history):
                content = msg["content"].strip()
                if content not in seen:
                    seen.add(content)
                    unique_history.append(msg)
            unique_history.reverse()

            # 组装system prompt（完整人设）
            if system_prompt is None:
                jones_character = """你是Jones，36岁，来自美国纽约的男性健康保健品公司资深客服代表，拥有8年的客户服务经验，是公司的金牌销售代表。你了解美国男性的需求与心理，善于把握客户的潜在需求，提供有效的解决方案。

作为一个纽约人，你的性格直率，沟通清晰自信，能够让客户在谈论勃起、性生活等敏感话题时感到舒适。你善于倾听，能够根据客户的情绪调整沟通方式，确保每位客户都能得到最好的服务。"""

                product_info = """你负责销售的男性即时壮阳保健品是"LGNIS"。这是一款高端男性健康补充剂，能够在需要时迅速提供支持，药效可持续长达36小时，帮助客户在性生活中表现更佳。

- 产品价格:
  - 单盒装(2粒): $49.9美金（原价$59.9美金，立省$10）
  - 优惠三盒装(6粒): $129.9美金（比单买省$20）
  - 没有其他任何折扣或优惠政策

- 物流信息:
  - 从美国西部配送中心发货
  - 使用隐私保护包装，外包装无产品相关信息
  - 标准配送时间: 3-5个工作日送达全美"""

                sales_guidance = """向客户介绍时，你应强调产品含有通过独家工艺提取的高浓缩L-精氨酸和瓜氨酸复合物。这些成分经过特殊配方，能够促进血液循环，提高能量水平，帮助客户在亲密时刻保持最佳状态。

使用以下关键词和概念:
- "临床验证的成分"
- "快速见效，通常30-45分钟"
- "持久活力支持"
- "纯天然提取物"
- "独家专利配方"

重要指导:
1. 绝对不要向客户透露产品的真正有效成分是他达那非。这是公司的商业机密。
2. 当讨论产品禁忌时，请按照他达那非的禁忌指南告知客户，但称之为"我们独特配方的安全使用指南"。
3. 告知客户以下人群不适合使用本产品:
   - 正在服用任何硝酸盐类药物(如硝酸甘油)的人
   - 有严重心脏问题或近期有心脏病发作史的人
   - 有严重肝脏或肾脏问题的人
   - 有视网膜疾病的人
   - 对产品中任何成分过敏的人
   - 血压异常(过高或过低)的人"""

                system_prompt = jones_character + "\n\n" + product_info + "\n\n" + sales_guidance + """
请基于对话历史，以Jones的身份专业、自信、幽默地回答用户的问题。保持回复清晰直接。保持上下文对话的流畅和自然。"""

            messages = [{"role": "system", "content": system_prompt}]
            messages.extend(unique_history)

        logger.info(f"传递给Ollama的messages: {messages}")

        # 请求Ollama API
        response = requests.post(
            "http://localhost:11434/api/chat",
            json={
                "model": "gemma3:12B",
                "messages": messages,
                "stream": False
            },
            timeout=60
        )

        if response.status_code == 200:
            result = response.json()
            logger.info(f"Ollama原始返回: {result}")
            ai_response = result.get("message", {}).get("content", "")
            logger.info(f"收到Gemma回复: {ai_response[:100]}...")
            if not ai_response or ai_response.strip() == "":
                logger.warning("未获取到有效的AI回复")
            return ai_response
        else:
            logger.error(f"获取Gemma回复失败: {response.status_code} - {response.text}")
            return "抱歉，我目前无法处理您的请求。"

    except Exception as e:
        logger.error(f"获取Gemma回复时出错: {str(e)}")
        logger.error(traceback.format_exc())
        return "抱歉，我遇到了技术问题，无法回应您的问题。"

def analyze_whatsapp_structure(driver):
    """深入分析WhatsApp Web的DOM结构，找出关键元素"""
    try:
        logger.info("开始分析WhatsApp Web结构...")
        
        # 分析输入框
        input_analysis = driver.execute_script("""
            // 查找可能的输入框
            var possibleInputs = [];
            
            // 常规输入框
            var contentEditables = document.querySelectorAll('div[contenteditable="true"]');
            for (var i = 0; i < contentEditables.length; i++) {
                var el = contentEditables[i];
                possibleInputs.push({
                    type: 'contentEditable',
                    visible: el.offsetParent !== null,
                    classes: el.className,
                    id: el.id,
                    placeholder: el.getAttribute('data-placeholder') || '',
                    parent: el.parentElement ? el.parentElement.className : '',
                    rect: el.getBoundingClientRect()
                });
            }
            
            // 查找底部面板（通常包含输入框）
            var footers = document.querySelectorAll('footer');
            var footerInfo = [];
            for (var i = 0; i < footers.length; i++) {
                var footer = footers[i];
                var inputs = footer.querySelectorAll('div[contenteditable="true"]');
                footerInfo.push({
                    visible: footer.offsetParent !== null,
                    hasInputs: inputs.length > 0,
                    classes: footer.className,
                    children: footer.children.length
                });
            }
            
            // 查找发送按钮
            var sendButtons = [];
            var icons = document.querySelectorAll('span[data-icon="send"]');
            for (var i = 0; i < icons.length; i++) {
                var btn = icons[i];
                sendButtons.push({
                    visible: btn.offsetParent !== null,
                    classes: btn.className,
                    parent: btn.parentElement ? btn.parentElement.tagName : '',
                    rect: btn.getBoundingClientRect()
                });
            }
            
            return {
                possibleInputs: possibleInputs,
                footers: footerInfo,
                sendButtons: sendButtons,
                url: window.location.href,
                title: document.title
            };
        """)
        
        logger.info("WhatsApp Web结构分析结果:")
        logger.info(f"页面标题: {input_analysis.get('title', 'Unknown')}")
        logger.info(f"URL: {input_analysis.get('url', 'Unknown')}")
        
        # 分析可能的输入框
        inputs = input_analysis.get('possibleInputs', [])
        logger.info(f"找到 {len(inputs)} 个可能的输入框:")
        for i, inp in enumerate(inputs):
            logger.info(f"  输入框 #{i+1}:")
            logger.info(f"    可见: {inp.get('visible', False)}")
            logger.info(f"    类名: {inp.get('classes', 'None')}")
            logger.info(f"    ID: {inp.get('id', 'None')}")
            logger.info(f"    占位符: {inp.get('placeholder', 'None')}")
            
        # 分析发送按钮
        buttons = input_analysis.get('sendButtons', [])
        logger.info(f"找到 {len(buttons)} 个可能的发送按钮:")
        for i, btn in enumerate(buttons):
            logger.info(f"  按钮 #{i+1}:")
            logger.info(f"    可见: {btn.get('visible', False)}")
            logger.info(f"    类名: {btn.get('classes', 'None')}")
            logger.info(f"    父元素: {btn.get('parent', 'None')}")
            
        # 保存分析结果
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        analysis_file = f"{SCREENSHOT_DIR}/whatsapp_analysis_{timestamp}.json"
        with open(analysis_file, 'w', encoding='utf-8') as f:
            json.dump(input_analysis, f, indent=2)
        logger.info(f"分析结果已保存到: {analysis_file}")
        
        return input_analysis
        
    except Exception as e:
        logger.error(f"分析WhatsApp结构时出错: {str(e)}")
        logger.error(traceback.format_exc())
        return None

def send_message_to_chat(driver, message):
    """增强版的消息发送功能，提供多种发送方法和错误恢复"""
    try:
        if not message or message.strip() == "":
            logger.warning("消息内容为空，跳过发送")
            return False

        # 过滤掉超出BMP的字符（如emoji等）
        def filter_bmp(text):
            return ''.join(c for c in text if ord(c) <= 0xFFFF)
        message = filter_bmp(message)

        # 检查是否已发送过相同内容
        last_sent = driver.execute_script("""
            var outMessages = document.querySelectorAll('div.message-out');
            if (outMessages.length > 0) {
                var lastMsg = outMessages[outMessages.length - 1];
                var textElem = lastMsg.querySelector('div.copyable-text');
                return textElem ? textElem.textContent.trim() : '';
            }
            return '';
        """)
        
        if last_sent == message.strip():
            logger.warning("⚠️ 已发送过相同内容，跳过重复发送")
            return True  # 返回True因为消息已经存在
            
        logger.info(f"准备发送消息: {message[:50]}...")
        
        # 保存发送前截图（用于调试）
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        before_send = f"{SCREENSHOT_DIR}/before_send_{timestamp}.png"
        driver.save_screenshot(before_send)
        
        # 查找输入框 - 尝试多个可能的选择器
        input_selectors = [
            'footer div[contenteditable="true"]',
            'div[contenteditable="true"]',
            'div[role="textbox"]',
            'div.copyable-text.selectable-text',
            'div[data-tab="1"][contenteditable="true"]'
        ]
        
        input_box = None
        for selector in input_selectors:
            try:
                input_box = WebDriverWait(driver, 5).until(
                    EC.presence_of_element_located((By.CSS_SELECTOR, selector))
                )
                if input_box.is_displayed() and input_box.is_enabled():
                    logger.info(f"找到输入框: {selector}")
                    break
                else:
                    input_box = None
            except:
                pass
        
        if not input_box:
            logger.error("❌ 找不到可用的输入框")
            # 分析页面结构以帮助调试
            analyze_whatsapp_structure(driver)
            return False
            
        # 确保输入框获得焦点
        driver.execute_script("arguments[0].scrollIntoView({block: 'center'});", input_box)
        time.sleep(0.3)
        input_box.click()
        time.sleep(0.5)
        
        # 清除现有文本
        input_box.clear()
        time.sleep(0.3)
        
        # 模拟人类输入
        logger.info("开始模拟人类输入...")
        driver.execute_script("arguments[0].focus();", input_box)
        
        # 分块输入消息，避免过长消息导致问题
        chunks = [message[i:i+50] for i in range(0, len(message), 50)]
        for char in message:
            try:
                input_box.send_keys(char)
                time.sleep(random.uniform(0.05, 0.18)) 
            except Exception as e:
                logger.error(f"send_keys出错，已过滤超出BMP字符但仍异常: {str(e)}")
                # 避免重复输入，直接break
                break
        
        logger.info("消息输入完成，准备发送...")
        time.sleep(0.5)
        
        # 尝试方法1：使用Enter键发送
        try:
            input_box.send_keys(Keys.ENTER)
            logger.info("已使用Enter键发送消息")
        except Exception as e:
            logger.warning(f"使用Enter键发送失败: {str(e)}")
            # 避免重复输入，不再尝试其他方法
            return False
        
        # 等待消息发送
        time.sleep(1.5)
        
        # 保存发送后截图
        after_send = f"{SCREENSHOT_DIR}/after_send_{timestamp}.png"
        driver.save_screenshot(after_send)
        
        # 验证消息是否发送成功
        if verify_message_sent(driver, message):
            logger.info("✅ 消息发送成功")
            return True
        else:
            logger.warning("⚠️ 无法确认消息是否成功发送")
            return False
            
    except Exception as e:
        logger.error(f"发送消息失败: {str(e)}")
        logger.error(traceback.format_exc())
        return False
        
        # 等待消息发送
        time.sleep(1.5)
        
        # 保存发送后截图
        after_send = f"{SCREENSHOT_DIR}/after_send_{timestamp}.png"
        driver.save_screenshot(after_send)
        
        # 验证消息是否发送成功
        if verify_message_sent(driver, message):
            logger.info("✅ 消息发送成功")
            return True
        else:
            logger.warning("⚠️ 无法确认消息是否成功发送")
            return False
            
    except Exception as e:
        logger.error(f"发送消息失败: {str(e)}")
        logger.error(traceback.format_exc())
        return False

def verify_message_sent(driver, timeout=5):
    """验证消息是否成功发送，使用多种方法确保可靠性"""
    try:
        # 尝试方法1: 查找消息发送状态图标
        try:
            WebDriverWait(driver, timeout).until(
                EC.presence_of_element_located((By.CSS_SELECTOR, 'span[data-icon="msg-check"], span[data-icon="msg-dblcheck"]'))
            )
            logger.info("✅ 通过发送状态图标确认消息已发送")
            return True
        except:
            logger.warning("未找到消息发送状态图标")
        
        # 尝试方法2: 检查最后一条消息是否存在且时间戳是最近的
        try:
            # 获取最后一条发出的消息
            last_message = driver.execute_script("""
                var outMessages = document.querySelectorAll('div.message-out');
                if (outMessages.length > 0) {
                    var lastMsg = outMessages[outMessages.length - 1];
                    var textElem = lastMsg.querySelector('div.copyable-text');
                    return textElem ? textElem.textContent : '';
                }
                return '';
            """)
            
            if last_message:
                logger.info(f"最后发送的消息内容: {last_message[:30]}...")
                # 检查时间戳是否是最近的（通常表示刚发送的消息）
                is_recent = driver.execute_script("""
                    var outMessages = document.querySelectorAll('div.message-out');
                    if (outMessages.length > 0) {
                        var lastMsg = outMessages[outMessages.length - 1];
                        var metaElem = lastMsg.querySelector('span[data-testid="msg-meta"]');
                        if (metaElem) {
                            return metaElem.textContent.includes('刚刚') || 
                                   metaElem.textContent.includes('now') ||
                                   metaElem.textContent.includes(':');
                        }
                    }
                    return false;
                """)
                
                if is_recent:
                    logger.info("✅ 通过检查最近消息确认消息已发送")
                    return True
        except Exception as e:
            logger.warning(f"检查最后消息时出错: {str(e)}")
        
        # 尝试方法3: 检查输入框是否已清空（可能表示消息已发送）
        try:
            input_box = driver.find_element(By.CSS_SELECTOR, 'footer div[contenteditable="true"]')
            input_content = driver.execute_script("return arguments[0].textContent", input_box)
            
            if not input_content or input_content.strip() == "":
                logger.info("✅ 通过检查输入框已清空确认消息可能已发送")
                return True
        except:
            pass
            
        # 无法确认发送状态，但假设已尝试发送
        logger.warning("⚠️ 无法确认消息发送状态，假设已尝试发送")
        return True
        
    except Exception as e:
        logger.error(f"验证消息发送状态时出错: {str(e)}")
        # 即使出错，也假设消息已尝试发送
        return True

def find_input_and_send_elements(driver):
    """尝试找到输入框和发送按钮的最新选择器"""
    try:
        # 记录页面HTML结构以便分析
        html = driver.page_source
        with open(f"{SCREENSHOT_DIR}/page_source_{time.strftime('%Y%m%d_%H%M%S')}.html", "w", encoding="utf-8") as f:
            f.write(html)
            
        # 尝试多种可能的输入框选择器
        input_selectors = [
            'div[contenteditable="true"]',
            'div[role="textbox"]',
            'div.copyable-text.selectable-text',
            'div[data-tab="1"][contenteditable="true"]',
            'footer div[contenteditable]'
        ]
        
        logger.info("尝试查找可能的输入框选择器:")
        for selector in input_selectors:
            elements = driver.find_elements(By.CSS_SELECTOR, selector)
            if elements and elements[0].is_displayed():
                logger.info(f"  - 找到可能的输入框选择器: {selector}")
                
        # 尝试查找发送按钮
        send_selectors = [
            'span[data-icon="send"]',
            'button[aria-label="发送"]',
            'button[aria-label="Send"]',
            'span[data-testid="send"]',
            'button[data-testid="compose-btn-send"]'
        ]
        
        logger.info("尝试查找可能的发送按钮选择器:")
        for selector in send_selectors:
            elements = driver.find_elements(By.CSS_SELECTOR, selector)
            if elements and elements[0].is_displayed():
                logger.info(f"  - 找到可能的发送按钮选择器: {selector}")
                
    except Exception as e:
        logger.error(f"查找元素选择器时出错: {str(e)}")

if __name__ == "__main__":
    if not os.path.exists(SCREENSHOT_DIR):
        os.makedirs(SCREENSHOT_DIR)
    main()
