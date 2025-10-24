#!/usr/bin/env python3
"""
Test password hashing functionality
"""

def test_password_hashing():
    """Test different password hashing methods"""
    print("Testing Password Hashing...")
    print("=" * 50)
    
    # Test 1: Try bcrypt
    try:
        from passlib.context import CryptContext
        pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
        
        password = "test123"
        hashed = pwd_context.hash(password)
        verified = pwd_context.verify(password, hashed)
        
        print(f"✅ Bcrypt: Working")
        print(f"   Original: {password}")
        print(f"   Hashed: {hashed[:50]}...")
        print(f"   Verified: {verified}")
        
    except Exception as e:
        print(f"❌ Bcrypt: Failed - {e}")
        
        # Test 2: Try pbkdf2_sha256 as fallback
        try:
            pwd_context = CryptContext(schemes=["pbkdf2_sha256"], deprecated="auto")
            
            password = "test123"
            hashed = pwd_context.hash(password)
            verified = pwd_context.verify(password, hashed)
            
            print(f"✅ PBKDF2: Working as fallback")
            print(f"   Original: {password}")
            print(f"   Hashed: {hashed[:50]}...")
            print(f"   Verified: {verified}")
            
        except Exception as e2:
            print(f"❌ PBKDF2: Also failed - {e2}")
    
    print("=" * 50)

if __name__ == "__main__":
    test_password_hashing()

