"""python check_diagnose.py <concept_id> "the student's answer" """
import sys, json
from dotenv import load_dotenv
load_dotenv(override=True)
from store import db
from tutor import questions as tutor
from diagnose import classifier

cid = int(sys.argv[1])
answer = sys.argv[2]
q = tutor.question_for(cid)
print("Q:", q, "\n")
print(json.dumps(classifier.diagnose(cid, q, answer), indent=2))
